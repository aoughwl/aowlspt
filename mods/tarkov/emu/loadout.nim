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
import rand

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

  LoadoutApi* = 2
    ## THE BACKEND HALF OF THE VERSION HANDSHAKE. Bumped whenever a script can
    ## ask for something an older `tarkov.dll` would have silently ignored.
    ##
    ## The measured failure this exists to stop: a script calls `equipWeapon`,
    ## which sends a `magazine` field; a DEPLOYED tarkov.dll built before that
    ## field existed parses the spec, does not see `magazine`, mints the rifle
    ## alone and reports `placed=1` with no rejection. `applyGear` in the runner
    ## only detects a MISSING ROUTE (HTTP 404) -- an OLD route answers 200 and
    ## the run passes having tested nothing. That is precisely a check that
    ## cannot fail, and version-blindness is what made it possible.

  LoadoutCaps* = "loadout,verify,clear,slot,inside,stash,query,count," &
                 "condition,ammo,magazine,chamber,perentry,baseline,rejections"
    ## Capability TOKENS, one per thing a script may depend on, deliberately
    ## finer-grained than the api integer. A caller declares the tokens it needs
    ## and is refused BY NAME for the ones this build does not have -- "this
    ## install's tarkov.dll has no `magazine`" is actionable where "api 1 < 2"
    ## is not.
    ##
    ## This literal lives in THIS file, beside the code that implements every
    ## token, and not in `tarkov.nim` where the route is registered: a
    ## capability list kept next to the transport drifts from the feature, and a
    ## handshake that lies is worse than none.

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
    magazine*: string
      ## The magazine template to MOUNT INSIDE this item's `mod_magazine` slot.
      ##
      ## Only meaningful on a weapon, and it exists because a weapon is not a
      ## magazine. MEASURED on this database: `5447a9cd4bdc2dbd208b4567` (M4A1)
      ## declares `_props.Chambers[0]._name = "patron_in_weapon"` and NO
      ## `_props.Cartridges` at all, while `55d4887d4bdc2d962f8b4570` (STANAG)
      ## declares `_props.Cartridges` and no slots. So `ammo` alone on a weapon
      ## used to hit `cartridgeCapacity` -> 0 and be REFUSED with "the database
      ## declares no _props.Cartridges[0]._max_count", and even had it not been,
      ## nothing was ever mounted in `mod_magazine` -- which is why the client's
      ## `GetCurrentMagazine()` came back null and every in-raid magazine cycle
      ## was dead on arrival.
      ##
      ## The magazine is NAMED by the script and never guessed. The M4A1's
      ## `mod_magazine` filter admits 20 templates; picking "the first" is an
      ## arbitrary document order, and this module already refuses that shape of
      ## guess in `resolve`.
    chamber*: bool
      ## Whether to put one round of `ammo` in the template's chamber. Defaults
      ## true whenever `ammo` is given and the template declares `_props.Chambers`
      ## -- a weapon spawned with a full magazine and an empty chamber is a weapon
      ## whose first trigger pull racks instead of fires, which is exactly the
      ## kind of state that makes a trigger-fires test read as a feature bug.
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
    magPlaced*: int
      ## How many magazines of `magazine` were READ BACK parented to the item
      ## this request minted, in slot `mod_magazine`. Counted from the re-read
      ## profile like `placed`, never from a counter this module incremented.
      ## `magazine` asked for and `magPlaced == 0` is a FAIL, and it is the
      ## falsifiable half of the weapon fix: point `magazine` at a template the
      ## weapon's filter does not admit and this number stays zero.
    roundsPlaced*: int
      ## Rounds READ BACK inside that mounted magazine (its `cartridges` child's
      ## `StackObjectsCount`). Zero with a magazine present means a magazine
      ## arrived empty, which looks identical to "the feature never fired" from
      ## inside a raid and is why it is counted separately.
    chambered*: int     ## rounds read back in the chamber slot, 0 or 1
    mintedId*: string
      ## The `_id` of the item this request minted into a worn slot or a
      ## container. Kept so the finished-state required-slot audit has a root to
      ## walk from -- it is the ONE thing carried across from the mint, and it
      ## is an identity, not a count.
    reqFound*: int
      ## Required slots (`_props.Slots[]._required`, recursively) discovered on
      ## the RE-READ item tree under `mintedId`.
    reqFilled*: int
      ## Of those, ones that have a child on the re-read tree.
    reqEmpty*: seq[string]
      ## The ones that do NOT, one line each. **This is the list that must be
      ## empty**, and it is the falsifiable negative behind the receiver-only
      ## rifle: `reqFound - reqFilled` parts missing means the player spawns
      ## holding a gun that does not work. Derived from the database and the
      ## saved profile, sharing nothing with the code that minted the parts.
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
    requiredFound*: int
      ## Required slots found across every minted item, on the RE-READ profile.
    requiredEmpty*: int
      ## Of those, ones with no child. **Must be zero.** Non-zero is a FAIL and
      ## every one is also in `rejected` by name, because "the rifle arrived"
      ## and "the rifle works" are different questions and only the second one
      ## is what the player experiences.
    requiredUnfillable*: seq[string]
      ## Required slots the minter could not fill at all -- the database names
      ## no candidate. Reported separately from `requiredEmpty` because it is a
      ## DATA gap, not a code gap, and the two want different fixes.

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

proc resolveNamed(q: string; why: var string): string =
  ## `magazine` / `ammo` -> ONE template id, by the rule `resolve` applies to
  ## `query`: a 24-hex id is kept verbatim (its existence is checked at mint
  ## time, as before), a NAME must match exactly one item, and ambiguity is
  ## refused with the candidates named. MEASURED 2026-09-05, first spawned kit
  ## in a live raid: the shipped AK-74N entry names its magazine ("6L20
  ## 30-round magazine"), that text went verbatim into the mod_magazine
  ## filter check, and the rifle spawned with NO magazine under the refusal
  ## "filter does not admit 6l20 30-round magazine" -- a name compared against
  ## template ids can never be admitted. Resolving here is what makes a name
  ## in these two fields mean what the kit's own comments say it means.
  why = ""
  if q.len == 24 and isTemplateId(q):
    return toLowerAscii(q)
  var matched = 0
  let hits = searchItemsCounted(q, 8, matched)
  if hits.len == 0:
    why = "no item matches \"" & q & "\""
    return ""
  if matched > 1:
    var names = ""
    for h in hits:
      if names.len > 0: names.add "; "
      names.add h.name & " (" & h.tpl & ")"
    why = "\"" & q & "\" matches " & $matched &
          " items -- narrow it or paste an id: " & names
    return ""
  result = hits[0].tpl

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
                    inside: "", count: 1, ammo: "", magazine: "", chamber: false,
                    condition: 100,
                    baseline: 0, minted: 0, placed: 0, magPlaced: 0,
                    roundsPlaced: 0, chambered: 0, mintedId: "",
                    reqFound: 0, reqFilled: 0, reqEmpty: @[], why: "")
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
    r.ammo = e.field("ammo").asText("")
    r.magazine = e.field("magazine").asText("")
    if r.magazine.len > 0 and r.ammo.len == 0:
      problems.add "gear[" & $i & "] (" & r.query & ") names a `magazine` but " &
                   "no `ammo`. A mounted magazine with nothing in it is a " &
                   "weapon that spawns empty, which is indistinguishable in " &
                   "raid from the magazine never having been mounted -- say " &
                   "which round it holds."
      continue
    # Both may be names (see `resolveNamed`); an id passes through unchanged.
    if r.magazine.len > 0:
      var wMag = ""
      let magTpl = resolveNamed(r.magazine, wMag)
      if magTpl.len == 0:
        problems.add "gear[" & $i & "] (" & r.query & ") `magazine`: " & wMag
        continue
      r.magazine = magTpl
    if r.ammo.len > 0:
      var wAmmo = ""
      let ammoTpl = resolveNamed(r.ammo, wAmmo)
      if ammoTpl.len == 0:
        problems.add "gear[" & $i & "] (" & r.query & ") `ammo`: " & wAmmo
        continue
      r.ammo = ammoTpl
    # `chamber` defaults to true when ammo was named. The default is only ACTED
    # ON if the template really declares `_props.Chambers`; `chamberName` below
    # is what decides that, so asking for a chamber on a magazine is a no-op
    # rather than a fabricated slot.
    r.chamber = e.field("chamber").asBool(r.ammo.len > 0)
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

proc chamberName*(tpl: string): string =
  ## `_props.Chambers[0]._name`, or "" when the template declares no chamber.
  ##
  ## MEASURED: the M4A1 answers "patron_in_weapon" here and has no
  ## `_props.Cartridges` at all. This proc is the ONLY thing that decides a
  ## template is chamber-shaped -- there is no name heuristic, because "it is
  ## called a rifle" is not a fact about the database.
  let v = dbRead("templates.items." & tpl & "._props.Chambers")
  if not v.ok:
    return ""
  let first = at(whole(v.raw), 0)
  if not first.found:
    return ""
  result = first.field("_name").asText("")

proc slotAccepts*(parentTpl, slotName, childTpl: string; why: var string): bool =
  ## Does `parentTpl`'s slot `slotName` admit `childTpl`?
  ##
  ## Three genuinely different answers, and they are NOT collapsed:
  ##   true, why == ""    the filter names it
  ##   false, why != ""   the slot exists and its filter EXCLUDES it, or the
  ##                      slot does not exist on this template at all
  ##   true, why != ""    the slot exists and declares no readable filter, so
  ##                      nothing was checked. An unreadable filter constrains
  ##                      nothing -- the same reading `cartridgeAccepts` takes --
  ##                      but the caller is told it was not checked rather than
  ##                      being handed a green light it did not earn.
  ## BOTH `_props.Slots` AND `_props.Chambers` are searched, in that order.
  ##
  ## MEASURED, and it is the non-obvious part: the chamber `patron_in_weapon` is
  ## NOT in the M4A1's `_props.Slots` -- it is a separate array, `_props.Chambers`,
  ## with a byte-identical entry shape (`_name`, `_props.filters[0].Filter`, an
  ## 11-template ammunition whitelist). Searching only `Slots` made this proc
  ## answer "the M4A1 has no patron_in_weapon slot" for a chamber that plainly
  ## exists, which would have silently left every weapon unchambered while
  ## emitting a confident, wrong reason. In the ITEM TREE they are the same
  ## thing: a child whose `slotId` is that name.
  why = ""
  var found = false
  var filtered = false
  for arrayName in ["Slots", "Chambers"]:
    let v = dbRead("templates.items." & parentTpl & "._props." & arrayName)
    if not v.ok:
      continue
    let slots = whole(v.raw)
    if not isArray(slots):
      continue
    for s in each(slots):
      if s.field("_name").asText("") != slotName:
        continue
      found = true
      let f = s.field("_props").field("filters").at(0).field("Filter")
      if not f.found or not isArray(f) or count(f) == 0:
        why = parentTpl & "'s " & slotName & " slot declares no readable " &
              "template filter, so COMPATIBILITY WAS NOT CHECKED"
        return true
      filtered = true
      for one in each(f):
        if one.asText("") == childTpl:
          return true
  if not found:
    why = parentTpl & " has no " & slotName & " slot (neither _props.Slots " &
          "nor _props.Chambers names one), so " & childTpl &
          " cannot be mounted in it"
    return false
  if filtered:
    why = parentTpl & "'s " & slotName & " filter does not admit " & childTpl &
          "; the client would drop it on load, so it was not minted"
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
    let ch = chamberName(parentTpl)
    if ch.len > 0:
      # The distinguishing case, and the one that used to read as a database
      # defect. This template is not a magazine: it is a CHAMBERED item, and it
      # holds its ammunition in a mounted magazine plus one round in `ch`.
      why = parentTpl & " declares no _props.Cartridges -- it is a CHAMBERED " &
            "item (_props.Chambers[0]._name = " & ch & "), so it holds no " &
            "rounds directly. Name a `magazine` alongside `ammo` and the " &
            "magazine is mounted in its mod_magazine slot and loaded; the " &
            "chamber is filled separately. Asking a weapon to behave like a " &
            "magazine is what produced a null GetCurrentMagazine() in raid."
    else:
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

proc chamberRound(items: var List; parentId, parentTpl, ammoTpl: string;
                  why: var string): int =
  ## Put ONE round of `ammoTpl` in `parentTpl`'s chamber slot. Returns 1 or 0.
  ##
  ## The chamber is a SLOT, not a cartridge array, so this mints a child whose
  ## `slotId` is the chamber's own `_name` -- "patron_in_weapon" on every weapon
  ## measured here -- and never the literal string, because a template that
  ## names its chamber differently would silently get an orphan child.
  result = 0
  why = ""
  if ammoTpl.len == 0:
    return
  let ch = chamberName(parentTpl)
  if ch.len == 0:
    # NOT an error: `chamber` defaults on, and a magazine has no chamber. Saying
    # nothing here is correct; saying "failed" would fail every magazine.
    return
  var w = ""
  if not slotAccepts(parentTpl, ch, ammoTpl, w):
    why = "the chamber was left empty -- " & w
    return
  var d = newDoc()
  setText(d, "_id", newId())
  setText(d, "_tpl", ammoTpl)
  setText(d, "parentId", parentId)
  setText(d, "slotId", ch)
  var upd = newDoc()
  setNumber(upd, "StackObjectsCount", 1)
  setRaw(d, "upd", text(upd))
  items.add d
  if w.len > 0:
    why = w      ## "compatibility was not checked" travels with the success
  result = 1

proc mountMagazine(items: var List; weaponId, weaponTpl, magTpl, ammoTpl: string;
                   magId: var string; rounds: var int; why: var string): bool =
  ## Mount `magTpl` in `weaponTpl`'s `mod_magazine` slot and load it.
  ##
  ## Returns false and populates `why` on every refusal. It refuses BEFORE
  ## minting when the weapon's filter excludes the magazine, because a magazine
  ## the client will drop on load is worse than no magazine: the profile saves,
  ## the read-back finds it, and the raid starts without it.
  magId = ""
  rounds = 0
  why = ""
  var w = ""
  if not slotAccepts(weaponTpl, "mod_magazine", magTpl, w):
    why = w
    return false
  let notChecked = w
  magId = newId()
  var d = newDoc()
  setText(d, "_id", magId)
  setText(d, "_tpl", magTpl)
  setText(d, "parentId", weaponId)
  setText(d, "slotId", "mod_magazine")
  items.add d
  var w2 = ""
  rounds = fillCartridges(items, magId, magTpl, ammoTpl, w2)
  if rounds == 0:
    # The magazine IS mounted; only the load failed. Both facts are reported,
    # because "no magazine" and "an empty magazine" fail a raid differently.
    why = "the magazine " & magTpl & " was mounted but loaded ZERO rounds -- " &
          w2
    return true
  if notChecked.len > 0:
    why = notChecked
  result = true

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
  # Required slots, from the FINISHED profile. `requiredEmpty` is the number
  # that must be zero; `requiredFound` is beside it so a zero that means "no
  # required slot was ever looked at" cannot be read as a pass.
  put(o, "requiredFound", rep.requiredFound)
  put(o, "requiredEmpty", rep.requiredEmpty)
  var unf = arr()
  for u in rep.requiredUnfillable:
    unf.add u
  put(o, "requiredUnfillable", unf)
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
    # The mounted-magazine numbers travel SEPARATELY from `placed`, for the same
    # reason requested/minted/placed do: "the rifle arrived" and "the rifle
    # arrived with a loaded magazine in it" are different claims, and a script
    # that could only see the first would report PASS on a weapon that cannot
    # be reloaded in raid.
    put(e, "magazine", r.magazine)
    put(e, "magPlaced", r.magPlaced)
    put(e, "roundsPlaced", r.roundsPlaced)
    put(e, "chambered", r.chambered)
    put(e, "requiredFound", r.reqFound)
    put(e, "requiredFilled", r.reqFilled)
    var pe = arr()
    for m in r.reqEmpty:
      pe.add m
    put(e, "requiredEmpty", pe)
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

proc countMounted(itemsJson: string; r: var GearReq; equipmentId: string) =
  ## Read `magPlaced` / `roundsPlaced` / `chambered` OFF THE RE-READ PROFILE.
  ##
  ## Deliberately shaped as a walk of the FINISHED STATE and not as a re-read of
  ## what `mountMagazine` just did: it starts from the equipment slot the script
  ## named, finds the item actually worn there, and only then looks for a child.
  ## Nothing it consults was produced by the mint path, so a magazine that was
  ## minted and then dropped by `validateSlots`, lost in the save, or written
  ## under the wrong parent lands here as a zero.
  ##
  ## The input that makes it fail is nameable: point `magazine` at a template the
  ## weapon's `mod_magazine` filter excludes, or at a magazine and no `ammo`, and
  ## `magPlaced` or `roundsPlaced` stays 0.
  r.magPlaced = 0
  r.roundsPlaced = 0
  r.chambered = 0
  if r.where != whEquip:
    return
  let list = parseArray(itemsJson)
  # 1. the item worn in the named slot, by id.
  var hostId = ""
  for i in 0 ..< list.len:
    let one = whole(list.items[i])
    if one.field("parentId").asText("") == equipmentId and
       one.field("slotId").asText("") == r.slot and
       one.field("_tpl").asText("") == r.tpl:
      hostId = one.field("_id").asText("")
      break
  if hostId.len == 0:
    return
  let ch = chamberName(r.tpl)
  # 2. its direct children: the magazine in mod_magazine, the chambered round.
  var magIds: seq[string] = @[]
  for i in 0 ..< list.len:
    let one = whole(list.items[i])
    if one.field("parentId").asText("") != hostId:
      continue
    let slot = one.field("slotId").asText("")
    if slot == "mod_magazine" and
       (r.magazine.len == 0 or one.field("_tpl").asText("") == r.magazine):
      r.magPlaced = r.magPlaced + 1
      magIds.add one.field("_id").asText("")
    elif ch.len > 0 and slot == ch:
      let n = one.field("upd").field("StackObjectsCount").asInt(1)
      r.chambered = r.chambered + (if n > 0: n else: 1)
  # 3. the rounds inside those magazines.
  if magIds.len == 0:
    return
  for i in 0 ..< list.len:
    let one = whole(list.items[i])
    if one.field("slotId").asText("") != "cartridges":
      continue
    let parent = one.field("parentId").asText("")
    var mine = false
    for m in magIds:
      if m == parent:
        mine = true
    if not mine:
      continue
    let n = one.field("upd").field("StackObjectsCount").asInt(1)
    r.roundsPlaced = r.roundsPlaced + (if n > 0: n else: 1)

proc applyLoadout*(body: string): LoadoutReport =
  ## Mint a declared loadout into a profile, then read the profile back and say
  ## what really arrived.
  result = LoadoutReport(verdict: "INCONCLUSIVE", reason: "", profileId: "",
                         requested: 0, minted: 0, placed: 0, rejected: @[], observations: @[],
                         reqs: @[], flatStacks: 0, slotDropped: 0, requiredFound: 0,
                         requiredEmpty: 0, requiredUnfillable: @[])
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
  # Seeded from the profile id, not from entropy: the same spec against the same
  # character fits the same parts, so a bug report naming a weapon can be
  # regenerated. `emu/rand` explains why nothing here is allowed a global RNG.
  var rng = seededRng(profileId)
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
      reqs[i].mintedId = nid
      if reqs[i].magazine.len > 0:
        # A weapon. The magazine goes IN it, and the ammo goes in the magazine;
        # `fillCartridges` on the weapon itself would refuse (measured: a weapon
        # declares Chambers, not Cartridges) and that refusal was the whole bug.
        var magId = ""
        var rounds = 0
        var why = ""
        if not mountMagazine(inv.items, nid, tpl, reqs[i].magazine,
                             reqs[i].ammo, magId, rounds, why):
          reqs[i].why = why
          result.rejected.add reqs[i].query & ": " & why
        elif rounds == 0:
          reqs[i].why = why
          result.rejected.add reqs[i].query & ": " & why
        elif why.len > 0:
          result.observations.add reqs[i].query & ": " & why
      elif reqs[i].ammo.len > 0 and chamberName(tpl).len == 0:
        # Only fill the item itself when it is NOT chamber-shaped. A chambered
        # item with `ammo` and no `magazine` falls through to the chamber below,
        # and `fillCartridges`'s own refusal names the missing `magazine`.
        var why = ""
        let rounds = fillCartridges(inv.items, nid, tpl, reqs[i].ammo, why)
        if rounds == 0 and why.len > 0:
          reqs[i].why = why
          result.rejected.add reqs[i].query & ": " & why
      if reqs[i].chamber and reqs[i].ammo.len > 0:
        var cw = ""
        if chamberRound(inv.items, nid, tpl, reqs[i].ammo, cw) == 0 and
           cw.len > 0:
          result.observations.add reqs[i].query & ": " & cw
      if reqs[i].ammo.len > 0 and reqs[i].magazine.len == 0 and
         chamberName(tpl).len > 0:
        let w = tpl & " is a chambered item and no `magazine` was named, so " &
                "it spawns with at most a chambered round and NO magazine. " &
                "GetCurrentMagazine() will read null in raid."
        reqs[i].why = w
        result.rejected.add reqs[i].query & ": " & w
      # THE FIX. A weapon template on its own is a RECEIVER: on this database
      # the M4A1 declares `mod_pistol_grip`, `mod_reciever`, `mod_stock` and
      # `mod_charge` as `_required`, its receiver requires `mod_barrel` and
      # `mod_handguard`, and that barrel requires `mod_gas_block`. Minting the
      # base template and running `validateSlots` -- which DROPS invalid
      # children and never FILLS missing required ones -- is exactly the gun a
      # player spawned holding on 2026-08-31.
      #
      # `emu/bots.fillRequiredSlots` is the same proc the bot generator uses, so
      # the player's rifle and a scav's rifle cannot disagree about what a
      # complete weapon is. It is a no-op on a template with no required slots,
      # which is why it is called unconditionally rather than behind a
      # "is this a weapon?" guess -- and it is NOT a no-op on body armour, which
      # declares `Soft_armor_front`/`_back`/`Helmet_top` and friends as required
      # (63, 63 and 59 templates respectively): a plate carrier minted without
      # them is a vest that stops nothing.
      var rf = RequiredFill(found: 0, already: 0, minted: 0, unfillable: @[])
      fillRequiredSlots(inv.items, nid, tpl, rng, rf)
      for u in rf.unfillable:
        # LOUD, and a refusal rather than an observation: this request produced
        # an item the player cannot use. Naming the slot is the correct outcome
        # -- silently shipping the broken weapon is not.
        result.requiredUnfillable.add u
        result.rejected.add reqs[i].query & ": " & u
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
        # A weapon put IN a rig is the same receiver-only item as one worn; the
        # audit below walks whichever copy this records, and `count > 1` on a
        # slotted item is already impossible (`limit <= 1` forces take = 1).
        if reqs[i].mintedId.len == 0:
          reqs[i].mintedId = nid
        var rfi = RequiredFill(found: 0, already: 0, minted: 0, unfillable: @[])
        fillRequiredSlots(inv.items, nid, tpl, rng, rfi)
        for u in rfi.unfillable:
          result.requiredUnfillable.add u
          result.rejected.add reqs[i].query & ": " & u
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
    countMounted(backItems, reqs[i], backEquip)
    if reqs[i].magazine.len > 0:
      # These are FAILS, not observations. A weapon whose magazine did not
      # survive the round trip is the exact state that made every in-raid
      # magazine cycle report a null GetCurrentMagazine(), and it is the thing
      # this feature exists to make impossible to ship silently.
      if reqs[i].magPlaced == 0:
        let w = "a " & reqs[i].magazine & " was asked for in " & reqs[i].tpl &
                "'s mod_magazine slot and NONE was read back off the saved " &
                "profile. GetCurrentMagazine() will read null in raid."
        if reqs[i].why.len == 0: reqs[i].why = w
        result.rejected.add reqs[i].query & ": " & w
      elif reqs[i].roundsPlaced == 0:
        let w = "the " & reqs[i].magazine & " IS mounted in " & reqs[i].tpl &
                " and read back ZERO rounds. An empty magazine is not a " &
                "loaded one; a reload test against it proves nothing."
        if reqs[i].why.len == 0: reqs[i].why = w
        result.rejected.add reqs[i].query & ": " & w
      else:
        result.observations.add reqs[i].query & ": read back " &
          $reqs[i].magPlaced & " x " & reqs[i].magazine & " in mod_magazine, " &
          $reqs[i].roundsPlaced & " round(s) inside, " & $reqs[i].chambered &
          " chambered"

    # ---- THE FINISHED-STATE REQUIRED-SLOT CHECK (CLAUDE.md 9b) ------------
    # Not "did I mint 7 parts". `validateSlots` runs between the mint and the
    # save and can remove one; the save itself can be lost. So this re-derives
    # which slots are required from the DATABASE, walks the tree as it exists in
    # `backItems` -- the profile read fresh off the store -- and asserts the
    # NEGATIVE: no required slot under the minted item is empty.
    #
    # The input that makes it FAIL: mint a weapon and skip filling one required
    # slot. `selfCheckLoadout` drives exactly that as a negative control, and if
    # it ever stops failing, this check has stopped being a check.
    if reqs[i].mintedId.len > 0:
      var missing: seq[string] = @[]
      var rfound = 0
      reqs[i].reqFilled = auditRequiredSlots(backItems, reqs[i].mintedId,
                                             missing, rfound)
      reqs[i].reqFound = rfound
      reqs[i].reqEmpty = missing
      result.requiredFound = result.requiredFound + rfound
      result.requiredEmpty = result.requiredEmpty + missing.len
      for m in missing:
        let w = reqs[i].label & " was read back off the saved profile with " &
                m & ". " & $rfound & " required slot(s), " &
                $reqs[i].reqFilled & " filled -- this item is INCOMPLETE and " &
                "will spawn as a bare receiver in raid."
        if reqs[i].why.len == 0: reqs[i].why = w
        result.rejected.add reqs[i].query & ": " & w
      if rfound > 0 and missing.len == 0:
        result.observations.add reqs[i].query & ": all " & $rfound &
          " required slot(s) filled on the saved profile"
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
                         reqs: @[], flatStacks: 0, slotDropped: 0, requiredFound: 0,
                         requiredEmpty: 0, requiredUnfillable: @[])
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
    # The same finished-state walk `applyLoadout` uses, so a "is my loadout
    # still intact after the raid?" check sees a magazine that was fired dry or
    # dropped, instead of only that the rifle is still worn.
    countMounted(itemsJson, reqs[i], equipmentId)
    if reqs[i].magazine.len > 0 and reqs[i].magPlaced == 0:
      let w = "no " & reqs[i].magazine & " is in " & reqs[i].tpl &
              "'s mod_magazine slot"
      if reqs[i].why.len == 0: reqs[i].why = w
      result.rejected.add reqs[i].query & ": " & w
    # The same required-slot audit `applyLoadout` runs, so "is my loadout still
    # intact?" also answers "is the rifle still a whole rifle?" -- a part
    # stripped in raid, or a loadout minted by an older build that had no notion
    # of `_required`, shows up here rather than in the player's hands.
    if reqs[i].where == whEquip:
      var wornTpl = ""
      let wornId = wornIn(openInventory(itemsJson).items, equipmentId,
                          reqs[i].slot, wornTpl)
      if wornId.len > 0:
        var missing: seq[string] = @[]
        var rfound = 0
        reqs[i].reqFilled = auditRequiredSlots(itemsJson, wornId, missing,
                                               rfound)
        reqs[i].reqFound = rfound
        reqs[i].reqEmpty = missing
        result.requiredFound = result.requiredFound + rfound
        result.requiredEmpty = result.requiredEmpty + missing.len
        for m in missing:
          let w = reqs[i].label & ": " & m
          if reqs[i].why.len == 0: reqs[i].why = w
          result.rejected.add reqs[i].query & ": " & w
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
                          reqs: @[], flatStacks: 0, slotDropped: 0, requiredFound: 0,
                         requiredEmpty: 0, requiredUnfillable: @[])
  let js = reportJson(rep)
  if js.find("\"requested\":3") < 0 or js.find("\"minted\":3") < 0 or
     js.find("\"placed\":0") < 0:
    into.add "loadout: the report does not carry requested/minted/placed as " &
             "three separate numbers"
    result = false

  # ---- the weapon / magazine fix ------------------------------------------
  #
  # These need the DATABASE but no profile, so they run wherever the mod is
  # loaded. Each one is a NEGATIVE: the thing that must be refused, refused.

  # `magazine` without `ammo` must be refused by the parser and must SAY so. An
  # empty mounted magazine is indistinguishable in raid from no magazine.
  var pid4 = ""
  var clr4 = false
  var probs4: seq[string] = @[]
  let noAmmo = parseSpec("{\"profileId\":\"a\",\"gear\":[{\"tpl\":" &
    "\"5447a9cd4bdc2dbd208b4567\",\"slot\":\"FirstPrimaryWeapon\"," &
    "\"magazine\":\"55d4887d4bdc2d962f8b4570\"}]}", pid4, clr4, probs4)
  if noAmmo.len != 0:
    into.add "loadout: `magazine` with no `ammo` was accepted; a magazine " &
             "mounted empty is not a loaded weapon"
    result = false
  if probs4.len == 0 or probs4[0].find("magazine") < 0:
    into.add "loadout: the refusal for `magazine` without `ammo` did not name " &
             "the field"
    result = false

  # The database-shape facts this whole feature rests on. If a Tarkov update
  # moves them, EVERY weapon loadout silently reverts to the old broken shape,
  # so they are asserted rather than assumed. Skipped, not failed, when the
  # database is not loaded -- "I could not look" is not a pass and is not a
  # failure either.
  if itemExists("5447a9cd4bdc2dbd208b4567") and
     itemExists("55d4887d4bdc2d962f8b4570"):
    if chamberName("5447a9cd4bdc2dbd208b4567") != "patron_in_weapon":
      into.add "loadout: the M4A1 no longer declares " &
               "_props.Chambers[0]._name = patron_in_weapon; the chambered-" &
               "item detection this feature rests on is stale"
      result = false
    if chamberName("55d4887d4bdc2d962f8b4570").len != 0:
      into.add "loadout: a STANAG magazine now reports a chamber, so " &
               "chamberName no longer distinguishes weapons from magazines"
      result = false
    if cartridgeCapacity("5447a9cd4bdc2dbd208b4567") != 0:
      into.add "loadout: the M4A1 now reports a cartridge capacity; the " &
               "weapon/magazine split this feature rests on has changed"
      result = false
    if cartridgeCapacity("55d4887d4bdc2d962f8b4570") <= 0:
      into.add "loadout: the STANAG magazine reports no cartridge capacity, " &
               "so no magazine can be loaded at all"
      result = false
    # The filter must ADMIT the STANAG and must REFUSE something it does not
    # list. A filter check that only ever says yes is not a check.
    var w1 = ""
    if not slotAccepts("5447a9cd4bdc2dbd208b4567", "mod_magazine",
                       "55d4887d4bdc2d962f8b4570", w1):
      into.add "loadout: the M4A1's mod_magazine filter no longer admits the " &
               "STANAG -- " & w1
      result = false
    var w2 = ""
    if slotAccepts("5447a9cd4bdc2dbd208b4567", "mod_magazine",
                   "590c678286f77426c9660122", w2):
      into.add "loadout: the M4A1's mod_magazine slot accepted an IFAK, so " &
               "the filter is not being read and NOTHING is being validated"
      result = false
    if w2.len == 0:
      into.add "loadout: a refused magazine produced no reason"
      result = false
    # A slot that does not exist must be refused as a missing slot, not as an
    # empty filter that admits everything.
    var w3 = ""
    if slotAccepts("55d4887d4bdc2d962f8b4570", "mod_magazine",
                   "55d4887d4bdc2d962f8b4570", w3):
      into.add "loadout: a magazine was said to have a mod_magazine slot"
      result = false
    # THE CHAMBER IS NOT IN `_props.Slots`. This assertion exists because the
    # first version of `slotAccepts` searched only `Slots`, answered "the M4A1
    # has no patron_in_weapon slot" for a chamber that plainly exists, and would
    # have left every weapon unchambered with a confident wrong reason. Caught
    # by cross-checking against db.json, not by the compiler.
    var w4 = ""
    if not slotAccepts("5447a9cd4bdc2dbd208b4567", "patron_in_weapon",
                       "54527ac44bdc2d36668b4567", w4):
      into.add "loadout: the M4A1's chamber will not admit M855A1 -- " & w4 &
               " (is _props.Chambers still being searched?)"
      result = false
    var w5 = ""
    if slotAccepts("5447a9cd4bdc2dbd208b4567", "patron_in_weapon",
                   "590c678286f77426c9660122", w5):
      into.add "loadout: the M4A1's chamber accepted an IFAK, so the chamber " &
               "filter is not being read"
      result = false

    # ---- required slots: the NEGATIVE CONTROL, then the fix ---------------
    #
    # CLAUDE.md 9b. `auditRequiredSlots` is the check that decides whether a
    # minted weapon is complete, so the first thing proved about it is that it
    # can say NO. A bare M4A1 -- one item document, no children, which is
    # EXACTLY what this module minted before 2026-08-31 and exactly what the
    # player spawned holding -- must be reported as INCOMPLETE. If this stops
    # failing, the audit has stopped being an audit and everything below it is
    # worthless.
    const BareM4 =
      "[{\"_id\":\"aaaaaaaaaaaaaaaaaaaa0001\"," &
      "\"_tpl\":\"5447a9cd4bdc2dbd208b4567\"," &
      "\"parentId\":\"aaaaaaaaaaaaaaaaaaaa0000\"," &
      "\"slotId\":\"FirstPrimaryWeapon\"}]"
    var bareMissing: seq[string] = @[]
    var bareFound = 0
    let bareFilled = auditRequiredSlots(BareM4, "aaaaaaaaaaaaaaaaaaaa0001",
                                        bareMissing, bareFound)
    if bareFound <= 0:
      into.add "loadout: the M4A1 declares NO required slots, so the " &
               "required-slot audit has nothing to assert and cannot fail. " &
               "Either the database changed or _props.Slots[]._required is no " &
               "longer being read -- INCONCLUSIVE, not a pass."
      result = false
    elif bareMissing.len == 0 or bareFilled != 0:
      into.add "loadout: NEGATIVE CONTROL FAILED -- a bare M4A1 with no parts " &
               "at all was reported as having " & $bareFilled & " of " &
               $bareFound & " required slots filled and " & $bareMissing.len &
               " empty. An audit that passes a receiver-only rifle is the bug."
      result = false
    elif bareMissing[0].find("_required") >= 0 and
         bareMissing[0].find("REQUIRED") < 0:
      into.add "loadout: the required-slot violation does not name the slot"
      result = false

    # Now the POSITIVE half, over the same input: `fillRequiredSlots` -- the
    # proc `emu/bots` uses -- must turn that bare receiver into a weapon the
    # SAME audit passes. Two independent things are asserted, not one: the
    # audit's own verdict flipped, and it flipped because parts exist on the
    # tree rather than because the audit was told to stop looking.
    var fixInv = openInventory(BareM4)
    var fixRng = seededRng("loadout-selfcheck")
    var rf = RequiredFill(found: 0, already: 0, minted: 0, unfillable: @[])
    fillRequiredSlots(fixInv.items, "aaaaaaaaaaaaaaaaaaaa0001",
                      "5447a9cd4bdc2dbd208b4567", fixRng, rf)
    if rf.minted <= 0:
      into.add "loadout: fillRequiredSlots fitted NOTHING to a bare M4A1, so " &
               "every minted weapon is still a receiver"
      result = false
    for u in rf.unfillable:
      into.add "loadout: a required slot on a stock M4A1 could not be " &
               "filled -- " & u
      result = false
    var fixedMissing: seq[string] = @[]
    var fixedFound = 0
    let fixedFilled = auditRequiredSlots(text(fixInv.items),
                                         "aaaaaaaaaaaaaaaaaaaa0001",
                                         fixedMissing, fixedFound)
    if fixedMissing.len != 0:
      into.add "loadout: after fillRequiredSlots, " & $fixedMissing.len &
               " required slot(s) on the M4A1 are STILL empty (" &
               fixedMissing[0] & ")"
      result = false
    if fixedFound <= bareFound or fixedFilled != fixedFound:
      into.add "loadout: the filled M4A1 reports " & $fixedFilled & " of " &
               $fixedFound & " required slots against " & $bareFound &
               " on the bare one. Required slots NEST (the receiver requires " &
               "a barrel, the barrel a gas block), so the filled tree must " &
               "declare MORE of them than the bare one -- a count that did " &
               "not grow means the walk is not recursing."
      result = false
    # And the parts that were fitted must survive the client's own rules. This
    # is the cross-check that the filter-derived templates are not merely
    # plausible: `validateSlots` is what the bot path and the mint path both run
    # before saving, and it refusing one of these would be a real signal.
    var vRep: seq[string] = @[]
    var vKept: seq[string] = @[]
    if validateSlots(fixInv.items, vRep, vKept) != 0:
      into.add "loadout: validateSlots REFUSED a part that fillRequiredSlots " &
               "took from the slot's own filter -- " &
               (if vRep.len > 0: vRep[0] else: "(no reason given)")
      result = false
