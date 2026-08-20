## What the player looks like: heads, suites, dog tags and voices.
##
## `templates.customization` is 728 entries and this server has always served
## it whole on `/client/customization`. What it never did was let the player
## *change* anything, which is the odd half of that pair: the wardrobe screen
## drew every suit in the game and the Apply button did nothing.
##
## ## The table's shape, because every rule below comes out of it
##
## It is a flat map of id -> entry, and the entries form a tree through
## `_parent`. Twenty-two of them are `_type: "Node"` — categories, not
## clothing — and the ones this file cares about are named `Head`, `Body`,
## `Feet`, `Hands`, `Upper`, `Lower`, `Voice` and `DogTags`. Everything else
## hangs off one of those.
##
## A profile's `Customization` block holds four ids — `Head`, `Body`, `Feet`,
## `Hands` — plus a `DogTag`, and `Info.Voice` holds a voice's **name** rather
## than its id. So the writes this file makes are exactly those five fields, and
## the client asks for them by `type`, not by field:
##
## | `type` | what it names | what it writes |
## |---|---|---|
## | `head` | an entry under `Head` | `Customization.Head` |
## | `suite` | an entry under `Upper` or `Lower` | see below |
## | `dogTag` | an entry under `DogTags` | `Customization.DogTag` |
## | `voice` | an entry under `Voice` | `Info.Voice`, as the entry's `_name` |
##
## **A suite is an indirection, and it is the reason this is a join rather than
## a copy.** An `Upper` entry carries no clothing of its own: its `_props` name
## a `Body` and a `Hands` entry, and a `Lower` entry names a `Feet` one. So
## applying one suite writes two fields, and both of the ids it names are
## themselves checked against the table before either is written.
##
## ## What is refused, and why refusing is the whole feature
##
## This is a write the client asks for by id. Believing it means a player — or
## anything sending requests to this port — can put any 24-character string in
## the field the client then tries to render, including one belonging to a
## different body part or to the other faction. So:
##
## - **an id the table does not have** is refused by name. A wrong id here is a
##   character with no head in the menu and no way to find out why.
## - **an id of the wrong part** is refused by name. `Feet` in the `Body` field
##   is the exact shape of the bug this file found in `emu/profile` (see the
##   note at the foot of this header), and it is invisible until a player looks
##   at their own character.
## - **an id belonging to the other side** is refused by name. `_props.Side` is
##   a list of `Bear`, `Usec` and `Savage`, and a Usec cannot wear a Bear kit.
##   An entry with an *empty* `Side` is refused too: the four in this database
##   are mannequin dressing and cultist voices, and "available to nobody" is the
##   reading that does not hand a player an asset the game never offers them.
## - **an id gated on an edition the profile does not have** is refused by name.
##   Five entries carry a non-empty `_props.ProfileVersions` — the Edge of
##   Darkness and Unheard dog tags — and they are checked against the profile's
##   `Info.GameVersion`.
##
## Two things are deliberately *not* checked, and both are stated here rather
## than left to be discovered:
##
## - **The parts a suite points at are not re-checked against the player's
##   side.** They are checked for body part, and not for side, because the data
##   says not to: `KillaUpperSuite` is available to `Bear`, `Usec` and `Savage`
##   and the body and hands it names are `Savage` only. It is the one entry in
##   165 that does this, and refusing it would refuse a suite the game offers.
## - **Whether the player has *unlocked* the thing.** Unlocks live in
##   `CustomisationUnlocks` on the real server's profile, filled by
##   `BuyCustomisation` and by quest and achievement rewards; this server has no
##   such list, because `trader/<id>/suits.json` is not in the imported
##   database and nothing else writes one. So every entry the table has and the
##   profile's side allows can be worn. That is more permissive than the game
##   and it is a stated gap, not an oversight.
##
## ## The bug this found on the way in
##
## The default `Customization` block a new profile is created with was
## scrambled, and had been since profiles were first written. Against the real
## table: `Head` was `DefaultBearHead` for Usec characters too; `Body` was
## `DefaultUsecBody` for Bear and `DefaulUsecFeet` — a **foot** — for Usec;
## `Feet` was `DefaultUsecHands` for Bear and `DefaultUsecBody` for Usec;
## `Hands` was `DefaultBearHands` for both. Seven of the eight ids were wrong,
## four of them naming the wrong body part outright.
##
## Nothing failed. The client resolves these against its own bundles, so the
## symptom is a character rendered wrongly or not at all, which reads as a mod
## problem rather than a server one. `selfCheckCustomisation` now runs the
## defaults through the same validator a `CustomizationSet` goes through, so a
## scramble of this kind stops the mod from loading rather than shipping.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import profile
import inventory

type
  CustomisePlan* = object
    ## The writes one `CustomizationSet` asks for, resolved and checked but not
    ## yet made. Paths are profile paths and values are raw JSON, so the caller
    ## writes them without knowing what any of them mean.
    ##
    ## Planned whole and applied whole, the same rule as every other write here:
    ## a request naming three things one of which is wrong changes none of them,
    ## because a half-applied outfit is a player who cannot tell what took.
    ok*: bool
    problem*: string
    paths*: seq[string]
    values*: seq[string]

proc newPlan(): CustomisePlan =
  CustomisePlan(ok: true, problem: "", paths: @[], values: @[])

proc refuse(problem: string): CustomisePlan =
  CustomisePlan(ok: false, problem: problem, paths: @[], values: @[])

proc customiseAction*(name: string): bool =
  ## `ItemEventActions.CUSTOMIZATION_SET`. The reference dump carries the enum
  ## member names and not their values, so this is the wire spelling the client
  ## uses — the same convention `emu/personal` states for its own actions.
  result = name == "CustomizationSet"

proc customisationTable*(): string =
  ## `templates.customization` as raw JSON, **"" when the database has no
  ## entries** — whether that is because the key is absent or because it is
  ## there and empty.
  ##
  ## "" rather than "{}", because the two mean different things to everything
  ## below: an empty table would refuse every id as "not in the table", and no
  ## table at all has to refuse the whole action naming the missing data. A
  ## server with no customization table cannot check an id at all, and the write
  ## it would make unchecked is one the player looks at for the rest of the
  ## wipe.
  ##
  ## **An empty object counts as no table, and that distinction was a live
  ## bug.** `selfCheckCustomisation` below runs its second half only when there
  ## *is* a table, and "the key is present" was the test. A database carrying
  ## `"customization": {}` — which `tools/benchbackend` generated — satisfied
  ## that, so the validator ran against nothing, found none of the ten default
  ## appearance ids, and the whole mod refused to load. A backend that logs
  ## `listening` and then answers nothing is the worst failure mode this file
  ## has, and it was reachable from a database that simply had no clothing in
  ## it. The precondition belongs here, once, where every caller inherits it:
  ## a table with no entries *is* the situation of not having one, and the two
  ## must behave the same everywhere.
  let v = dbRead("templates.customization")
  if v.ok and v.raw.len > 0 and members(whole(v.raw)).len > 0:
    return v.raw
  result = ""

proc branchOf*(tableJson, id: string): string =
  ## The `_name` of the node an entry hangs off — `Head`, `Upper`, `Voice` and
  ## so on. Empty when the entry or its parent is not there.
  ##
  ## Resolved through the tree rather than against hard-coded parent ids: the
  ## node ids are data like everything else, and a table that renumbers them is
  ## a table this still reads correctly.
  let parent = field(tableJson, id & "._parent").asText("")
  if parent.len == 0:
    return ""
  result = field(tableJson, parent & "._name").asText("")

proc entryAllowed*(tableJson, id, side, gameVersion: string;
                   problem: var string): bool =
  ## The checks every entry gets whatever slot it is going into: it exists, it
  ## is a real entry rather than a category, this side may wear it, and this
  ## profile's edition may have it.
  problem = ""
  if id.len == 0:
    problem = "that request names no customisation id"
    return false
  let entry = field(tableJson, id)
  if not entry.found:
    problem = "there is no customisation " & id & " in this server's database"
    return false
  if entry.field("_type").asText("") == "Node":
    problem = "customisation " & id & " is a category and not something to wear"
    return false

  let sides = entry.field("_props.Side")
  var allowed = false
  if sides.found:
    let list = each(sides)
    for s in list:
      if s.asText("") == side:
        allowed = true
  if not allowed:
    problem = "customisation " & id & " (" &
              entry.field("_props.Name").asText(id) & ") is not available to " &
              side
    return false

  let versions = entry.field("_props.ProfileVersions")
  if versions.found and count(versions) > 0:
    var hasVersion = false
    let list = each(versions)
    for v in list:
      if v.asText("") == gameVersion:
        hasVersion = true
    if not hasVersion:
      problem = "customisation " & id & " belongs to another edition of the " &
                "game and this profile is " & gameVersion
      return false
  result = true

proc slotAllowed*(tableJson, id, side, gameVersion, slot: string;
                  problem: var string): bool =
  ## `entryAllowed`, plus: the entry is of the body part the slot names.
  ##
  ## `slot` is one of `Head`, `Body`, `Feet`, `Hands` and `DogTag`, which are
  ## the profile's own field names. The first four are matched against
  ## `_props.BodyPart`, which the table states outright; `DogTag` has no body
  ## part and is matched against the branch it hangs off instead.
  if not entryAllowed(tableJson, id, side, gameVersion, problem):
    return false
  if slot == "DogTag":
    let branch = branchOf(tableJson, id)
    if branch != "DogTags":
      problem = "customisation " & id & " is a " &
                (if branch.len > 0: branch else: "unplaced entry") &
                " and not a dog tag"
      return false
    return true
  let part = field(tableJson, id & "._props.BodyPart").asText("")
  if part != slot:
    problem = "customisation " & id & " is " &
              (if part.len > 0: "a " & part else: "not a body part") &
              " and cannot go in the " & slot & " slot"
    return false
  result = true

proc addSuitePart(tableJson, suiteId, prop: string;
                  plan: var CustomisePlan): bool =
  ## One of the parts a suite names. Its **side is deliberately not checked** —
  ## see the header for `KillaUpperSuite`, the one entry in 165 that settles it:
  ## a suite available to every side names parts that are `Savage` only, and
  ## re-checking here would refuse a suite the game offers. The player was
  ## already checked against the suite itself, which is the thing the wardrobe
  ## screen offered them.
  ##
  ## The body part *is* checked, because a suite naming a head as its body would
  ## put a head in the body field and nothing downstream would notice.
  let partId = field(tableJson, suiteId & "._props." & prop).asText("")
  if partId.len == 0:
    plan = refuse("suite " & suiteId & " names no " & prop &
                  ", so this server cannot say what wearing it means")
    return false
  if not field(tableJson, partId).found:
    plan = refuse("suite " & suiteId & " names " & partId & " as its " & prop &
                  " and there is no such entry in this server's database")
    return false
  let part = field(tableJson, partId & "._props.BodyPart").asText("")
  if part != prop:
    plan = refuse("suite " & suiteId & " names " & partId & " as its " & prop &
                  " and that entry is " &
                  (if part.len > 0: "a " & part else: "not a body part"))
    return false
  plan.paths.add "Customization." & prop
  plan.values.add "\"" & partId & "\""
  result = true

proc planCustomisation*(tableJson, side, gameVersion, optionsJson: string):
    CustomisePlan =
  ## Every write a `CustomizationSet` asks for, or the first refusal.
  ##
  ## `optionsJson` is the request's `customizations` array:
  ## `[{id, type, source}]` — `CustomizationSetOption` in the reference, whose
  ## members are `Id`, `Type` and `Source`. `source` says where the client
  ## thinks the entry came from and is not read: this server has no unlock list
  ## to reconcile it against, and a field whose only use would be to be believed
  ## is better left alone than pretended to be a check.
  if tableJson.len == 0:
    return refuse("this server's database has no customization table, so it " &
                  "cannot tell whether any of that is real; nothing was " &
                  "changed")
  let options = whole(optionsJson)
  if not options.found or not isArray(options):
    return refuse("that request names no customisations to set")
  if count(options) == 0:
    return refuse("that request names no customisations to set")

  result = newPlan()
  let list = each(options)
  for opt in list:
    var id = opt.field("id").asText("")
    if id.len == 0:
      id = opt.field("Id").asText("")
    var kind = opt.field("type").asText("")
    if kind.len == 0:
      kind = opt.field("Type").asText("")

    var problem = ""
    case kind
    of "suite":
      if not entryAllowed(tableJson, id, side, gameVersion, problem):
        return refuse(problem)
      let branch = branchOf(tableJson, id)
      if branch == "Upper":
        if not addSuitePart(tableJson, id, "Body", result):
          return result
        if not addSuitePart(tableJson, id, "Hands", result):
          return result
      elif branch == "Lower":
        if not addSuitePart(tableJson, id, "Feet", result):
          return result
      else:
        return refuse("customisation " & id & " is " &
                      (if branch.len > 0: "a " & branch else: "unplaced") &
                      " and not a suite")
    of "head":
      if not slotAllowed(tableJson, id, side, gameVersion, "Head", problem):
        return refuse(problem)
      result.paths.add "Customization.Head"
      result.values.add "\"" & id & "\""
    of "dogTag":
      if not slotAllowed(tableJson, id, side, gameVersion, "DogTag", problem):
        return refuse(problem)
      result.paths.add "Customization.DogTag"
      result.values.add "\"" & id & "\""
    of "voice":
      if not entryAllowed(tableJson, id, side, gameVersion, problem):
        return refuse(problem)
      if branchOf(tableJson, id) != "Voice":
        return refuse("customisation " & id & " is not a voice")
      # `Info.Voice` holds the entry's *name*, not its id -- a profile is
      # created with "Usec_1" and that is what the client reads back. An entry
      # with no name cannot be applied, and saying so beats writing an empty
      # string into a field the character menu renders.
      let name = field(tableJson, id & "._props.Name").asText("")
      if name.len == 0:
        return refuse("voice " & id & " has no name in this server's database")
      result.paths.add "Info.Voice"
      result.values.add "\"" & name & "\""
    of "":
      return refuse("that request names customisation " & id &
                    " without saying what it is")
    else:
      # `CustomisationType` in the reference also has floor, wall, ceiling,
      # light, mannequinPose, shootingRangeMark, environment, gesture and cat.
      # Those are the hideout's, they belong to `HideoutCustomizationApply`
      # and its `CustomisationUnlocks` list, and neither is served here.
      # Refused by name rather than dropped: a player who redecorated and was
      # told nothing would find the room unchanged and no reason given.
      return refuse("this server does not set \"" & kind &
                    "\" customisations; " &
                    (if id.len > 0: id else: "that entry") &
                    " was left alone")
  result.ok = true

# ---------------------------------------------------------------------------
# The entry point that has a profile
# ---------------------------------------------------------------------------

proc applyCustomisation*(p: var Profile; body: JsonRef; ch: var Change): bool =
  ## `CustomizationSet`. Returns whether the profile changed.
  let plan = planCustomisation(customisationTable(), p.side,
                               p.field("Info.GameVersion").asText("standard"),
                               raw(body.field("customizations")))
  if not plan.ok:
    ch.problems.add "customisation: " & plan.problem
    return false
  for k in 0 ..< plan.paths.len:
    setRaw(p, plan.paths[k], plan.values[k])
  result = plan.paths.len > 0

proc plainId(id: string): bool =
  ## Whether an id is safe to put inside a JSON literal.
  ##
  ## `applyVoice` builds a one-element `customizations` array out of the id the
  ## client sent, so an id carrying a quote would be a body this server wrote
  ## and did not mean. Every id in `templates.customization` is 24 hex
  ## characters; the check is looser than that on purpose, because a fixture
  ## and a mod may key entries by name.
  if id.len == 0 or id.len > 64:
    return false
  for ch in id:
    let okChar = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                 (ch >= '0' and ch <= '9') or ch == '_' or ch == '-'
    if not okChar:
      return false
  result = true

proc applyVoice*(p: var Profile; voiceId: string; problem: var string): bool =
  ## `/client/game/profile/voice/change`. Returns whether the profile changed.
  ##
  ## This route used to be bound to the stock "ok" stub: it answered
  ## `{"status":"ok"}` and wrote nothing, so the voice selector on the
  ## character screen appeared to work and did not. That is the failure this
  ## whole server is written against, arrived at from the wrong side -- not a
  ## refusal the client swallows but a success the server invented -- and
  ## `docs/EMULATOR-COVERAGE.md` recorded it as "served".
  ##
  ## Everything it needs was already here. `ProfileChangeVoiceRequestData` in
  ## the reference dump has exactly one property, `MongoId Voice`, and
  ## `planCustomisation`'s `voice` arm already checks the entry exists, is
  ## under the `Voice` branch, is allowed for this side and edition, and writes
  ## the entry's `_name` rather than its id -- which is what `Info.Voice`
  ## holds. So this is that arm, reached by a second door, and a voice the
  ## table does not allow is refused by the same sentence either door.
  problem = ""
  if not plainId(voiceId):
    problem = "that request named no voice this server can look up"
    return false
  let plan = planCustomisation(customisationTable(), p.side,
                               p.field("Info.GameVersion").asText("standard"),
                               "[{\"id\":\"" & voiceId & "\",\"type\":\"voice\"}]")
  if not plan.ok:
    problem = plan.problem
    return false
  for k in 0 ..< plan.paths.len:
    setRaw(p, plan.paths[k], plan.values[k])
  result = plan.paths.len > 0

# ---------------------------------------------------------------------------
# The self-check
# ---------------------------------------------------------------------------

const CheckTable = """{
 "node_root":{"_id":"node_root","_name":"Customization","_parent":"",
   "_type":"Node","_props":{"Side":["Savage"]}},
 "node_parts":{"_id":"node_parts","_name":"BodyParts","_parent":"node_root",
   "_type":"Node","_props":{"Side":[]}},
 "node_head":{"_id":"node_head","_name":"Head","_parent":"node_parts",
   "_type":"Node","_props":{"Side":[]}},
 "node_body":{"_id":"node_body","_name":"Body","_parent":"node_parts",
   "_type":"Node","_props":{"Side":[]}},
 "node_feet":{"_id":"node_feet","_name":"Feet","_parent":"node_parts",
   "_type":"Node","_props":{"Side":[]}},
 "node_hands":{"_id":"node_hands","_name":"Hands","_parent":"node_parts",
   "_type":"Node","_props":{"Side":[]}},
 "node_suits":{"_id":"node_suits","_name":"Suits","_parent":"node_root",
   "_type":"Node","_props":{"Side":[]}},
 "node_upper":{"_id":"node_upper","_name":"Upper","_parent":"node_suits",
   "_type":"Node","_props":{"Side":[]}},
 "node_lower":{"_id":"node_lower","_name":"Lower","_parent":"node_suits",
   "_type":"Node","_props":{"Side":[]}},
 "node_voice":{"_id":"node_voice","_name":"Voice","_parent":"node_root",
   "_type":"Node","_props":{"Side":[]}},
 "node_tags":{"_id":"node_tags","_name":"DogTags","_parent":"node_root",
   "_type":"Node","_props":{"Side":[]}},

 "usec_head":{"_id":"usec_head","_name":"UsecHead","_parent":"node_head",
   "_type":"Item","_props":{"Name":"UsecHead","Side":["Usec"],
   "BodyPart":"Head","ProfileVersions":[]}},
 "bear_head":{"_id":"bear_head","_name":"BearHead","_parent":"node_head",
   "_type":"Item","_props":{"Name":"BearHead","Side":["Bear"],
   "BodyPart":"Head","ProfileVersions":[]}},
 "usec_body":{"_id":"usec_body","_name":"UsecBody","_parent":"node_body",
   "_type":"Item","_props":{"Name":"UsecBody","Side":["Usec"],
   "BodyPart":"Body","ProfileVersions":[]}},
 "usec_hands":{"_id":"usec_hands","_name":"UsecHands","_parent":"node_hands",
   "_type":"Item","_props":{"Name":"UsecHands","Side":["Usec"],
   "BodyPart":"Hands","ProfileVersions":[]}},
 "usec_feet":{"_id":"usec_feet","_name":"UsecFeet","_parent":"node_feet",
   "_type":"Item","_props":{"Name":"UsecFeet","Side":["Usec"],
   "BodyPart":"Feet","ProfileVersions":[]}},
 "usec_upper":{"_id":"usec_upper","_name":"UsecUpper","_parent":"node_upper",
   "_type":"Item","_props":{"Name":"UsecUpper","Side":["Usec"],
   "ProfileVersions":[],"Body":"usec_body","Hands":"usec_hands"}},
 "usec_lower":{"_id":"usec_lower","_name":"UsecLower","_parent":"node_lower",
   "_type":"Item","_props":{"Name":"UsecLower","Side":["Usec"],
   "ProfileVersions":[],"Feet":"usec_feet"}},
 "broken_upper":{"_id":"broken_upper","_name":"BrokenUpper",
   "_parent":"node_upper","_type":"Item","_props":{"Name":"BrokenUpper",
   "Side":["Usec"],"ProfileVersions":[],"Body":"usec_feet",
   "Hands":"usec_hands"}},
 "usec_voice":{"_id":"usec_voice","_name":"Usec_1","_parent":"node_voice",
   "_type":"Item","_props":{"Name":"Usec_1","Side":["Usec"],
   "ProfileVersions":[]}},
 "usec_tag":{"_id":"usec_tag","_name":"UsecTag","_parent":"node_tags",
   "_type":"Item","_props":{"Name":"UsecTag","Side":["Usec"],
   "ProfileVersions":[]}},
 "eod_tag":{"_id":"eod_tag","_name":"EodTag","_parent":"node_tags",
   "_type":"Item","_props":{"Name":"EodTag","Side":["Usec"],
   "ProfileVersions":["edge_of_darkness"]}},
 "nobody_voice":{"_id":"nobody_voice","_name":"Cultist",
   "_parent":"node_voice","_type":"Item","_props":{"Name":"Cultist",
   "Side":[],"ProfileVersions":[]}}
}"""

proc one(kind, id: string): string =
  "[{\"id\":\"" & id & "\",\"type\":\"" & kind & "\",\"source\":\"default\"}]"

proc wrote(plan: CustomisePlan; path, value: string): bool =
  for k in 0 ..< plan.paths.len:
    if plan.paths[k] == path and plan.values[k] == "\"" & value & "\"":
      return true
  result = false

proc selfCheckCustomisation*(into: var seq[string]): bool =
  ## The validator, against a literal table shaped like the real one, plus the
  ## defaults a new profile is created with against the **real** table when the
  ## database has one.
  ##
  ## That second half is the only check in `emu/selfchecks` that reads the
  ## database, and it is here rather than in a wire test because the wire test's
  ## fixture has no customization table and never will have 728 entries in it.
  ## It is skipped when the table is absent — a server started on the small
  ## fixture still loads — and it is what would have caught the scrambled
  ## defaults described in this file's header on the day they were written.
  let before = into.len

  # An id the table does not have.
  let unknown = planCustomisation(CheckTable, "Usec", "standard",
                                  one("head", "no_such_id"))
  if unknown.ok:
    into.add "customisation: an unknown head id was accepted"
  elif unknown.problem.find("no_such_id") < 0:
    into.add "customisation: refusing an unknown id did not name it: " &
             unknown.problem

  # The right kind of id in the wrong slot.
  let wrongPart = planCustomisation(CheckTable, "Usec", "standard",
                                    one("head", "usec_feet"))
  if wrongPart.ok:
    into.add "customisation: a Feet entry was accepted as a head"

  # The other faction's kit.
  let wrongSide = planCustomisation(CheckTable, "Usec", "standard",
                                    one("head", "bear_head"))
  if wrongSide.ok:
    into.add "customisation: a Bear head was accepted on a Usec profile"
  elif wrongSide.problem.find("Usec") < 0:
    into.add "customisation: refusing the wrong side did not name it: " &
             wrongSide.problem

  # An entry available to nobody.
  let nobody = planCustomisation(CheckTable, "Usec", "standard",
                                 one("voice", "nobody_voice"))
  if nobody.ok:
    into.add "customisation: an entry with an empty Side was accepted"

  # An edition gate.
  let locked = planCustomisation(CheckTable, "Usec", "standard",
                                 one("dogTag", "eod_tag"))
  if locked.ok:
    into.add "customisation: an edition-locked dog tag was accepted on a " &
             "standard profile"
  let unlocked = planCustomisation(CheckTable, "Usec", "edge_of_darkness",
                                   one("dogTag", "eod_tag"))
  if not unlocked.ok:
    into.add "customisation: an edition-locked dog tag was refused on the " &
             "edition that has it: " & unlocked.problem

  # A category is not a thing to wear.
  let node = planCustomisation(CheckTable, "Usec", "standard",
                               one("head", "node_head"))
  if node.ok:
    into.add "customisation: a category node was accepted as a head"

  # The suite indirection: one option, two writes.
  let upper = planCustomisation(CheckTable, "Usec", "standard",
                                one("suite", "usec_upper"))
  if not upper.ok:
    into.add "customisation: an upper suite was refused: " & upper.problem
  elif upper.paths.len != 2 or
       not wrote(upper, "Customization.Body", "usec_body") or
       not wrote(upper, "Customization.Hands", "usec_hands"):
    into.add "customisation: an upper suite did not write Body and Hands"

  let lower = planCustomisation(CheckTable, "Usec", "standard",
                                one("suite", "usec_lower"))
  if not lower.ok:
    into.add "customisation: a lower suite was refused: " & lower.problem
  elif lower.paths.len != 1 or not wrote(lower, "Customization.Feet",
                                         "usec_feet"):
    into.add "customisation: a lower suite did not write Feet"

  # A suite whose own table is wrong: its Body is a Feet entry.
  let broken = planCustomisation(CheckTable, "Usec", "standard",
                                 one("suite", "broken_upper"))
  if broken.ok:
    into.add "customisation: a suite naming a Feet entry as its Body was " &
             "accepted"

  # A voice writes its name, not its id.
  let voice = planCustomisation(CheckTable, "Usec", "standard",
                                one("voice", "usec_voice"))
  if not voice.ok:
    into.add "customisation: a voice was refused: " & voice.problem
  elif not wrote(voice, "Info.Voice", "Usec_1"):
    into.add "customisation: a voice did not write Info.Voice as its name"

  # A hideout type, refused by name rather than dropped.
  let hideout = planCustomisation(CheckTable, "Usec", "standard",
                                  one("floor", "usec_head"))
  if hideout.ok:
    into.add "customisation: a hideout \"floor\" set was accepted"
  elif hideout.problem.find("floor") < 0:
    into.add "customisation: refusing a hideout type did not name it: " &
             hideout.problem

  # All or nothing: a batch whose second entry is wrong writes neither.
  let mixed = planCustomisation(CheckTable, "Usec", "standard",
    "[{\"id\":\"usec_head\",\"type\":\"head\"}," &
    "{\"id\":\"bear_head\",\"type\":\"head\"}]")
  if mixed.ok or mixed.paths.len > 0:
    into.add "customisation: a batch with one bad entry was partly applied"

  # No table at all is a refusal that names the missing data.
  let noTable = planCustomisation("", "Usec", "standard",
                                  one("head", "usec_head"))
  if noTable.ok:
    into.add "customisation: a set was accepted with no customization table"

  # ---- the defaults, against the real table when there is one -------------
  #
  # "when there is one" means *with entries in it*, which `customisationTable`
  # now decides for every caller at once -- see the note there about the empty
  # object that made this check refuse the whole mod's load on a database that
  # merely had no clothing in it.
  let live = customisationTable()
  # The contract itself, pinned: a table this reports as present has entries in
  # it. This is the regression guard for the bug rather than a restatement of
  # it -- if `customisationTable` ever goes back to reporting an empty object as
  # a table, this line fails here, where the message names the cause, instead of
  # ten checks below where it reads as ten missing default appearances.
  if live.len > 0 and members(whole(live)).len == 0:
    into.add "customisation: an empty customization table was reported as " &
             "present; every check below it would fail against nothing"
  if live.len > 0:
    let sides = @["Usec", "Bear"]
    # Same order as `defaultCustomisation`: Head, Body, Feet, Hands, Voice,
    # DogTag. `Voice` is skipped here -- it is a voice node, not a wearable
    # slot, and is validated in its own pass below; without the skip the index
    # into `defaults` would misalign and DogTag would be checked against the
    # voice id.
    let slots = @["Head", "Body", "Feet", "Hands", "Voice", "DogTag"]
    for s in sides:
      let defaults = defaultCustomisation(s)
      for k in 0 ..< slots.len:
        if slots[k] == "Voice": continue
        var problem = ""
        if not slotAllowed(live, defaults[k], s, "standard", slots[k], problem):
          into.add "customisation: the " & s & " default " & slots[k] &
                   " does not validate: " & problem
    # The voices, in one pass over the table rather than a lookup per entry:
    # `field` scans from the top of the document every time it is called, and
    # this document is 728 entries of a megabyte or so. One pass at load is
    # nothing; 728 scans of it would be noticeable.
    var voiceFound: seq[bool] = @[]
    for s in sides:
      voiceFound.add false
    let entries = members(whole(live))
    var voiceNode = ""
    for e in entries:
      if field(e.value, "_type").asText("") == "Node" and
         field(e.value, "_name").asText("") == "Voice":
        voiceNode = e.name
    for e in entries:
      if voiceNode.len == 0 or
         field(e.value, "_parent").asText("") != voiceNode:
        continue
      let name = field(e.value, "_props.Name").asText("")
      for k in 0 ..< sides.len:
        if name == defaultVoice(sides[k]):
          voiceFound[k] = true
    for k in 0 ..< sides.len:
      if not voiceFound[k]:
        into.add "customisation: the " & sides[k] & " default voice " &
                 defaultVoice(sides[k]) &
                 " matches no Voice entry in this database"

  result = into.len == before
