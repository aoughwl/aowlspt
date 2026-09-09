## The starting kit: what a brand-new profile owns, per edition, per side.
##
## Everything here comes out of `templates.profiles` in the loaded database --
## SPT's `database/templates/profiles.json`, spliced in by `aowl importdb`.
## That table is the only place the real starting gear exists: a standard Usec
## carries **205** inventory items (a weapon, a rig, armour, a secure container,
## ammo, two rouble stacks) and 94 Encyclopedia entries; Edge Of Darkness
## carries 337 and four StashSize bonuses instead of one.
##
## Before this module the emulator synthesised five containers, Pockets and a
## money stack -- 7 items -- and handed the same 7 to every edition. The
## edition reached `Info.GameVersion` and nothing else, so picking Edge Of
## Darkness bought a label.
##
## Three rules this module keeps:
##
## 1. **A missing table is announced, never papered over.** `starterKit` returns
##    `ok = false` with a reason, and the caller falls back to the synthesised
##    profile *and says so in the log*. A server started without a database
##    still creates a working profile -- see `emu/profile` -- it just creates a
##    poor one, loudly.
## 2. **Every item id is fresh, per OCCURRENCE.** Not per distinct id: SPT's own
##    Standard template has 205 items with only **196 distinct `_id`s** (the
##    soft-armour plates of three different armour pieces share ids). A 1:1
##    old->new remap preserves that collision; the client then hangs three
##    plates off whichever parent it resolves first. Only the first occurrence
##    of an id is used to resolve `parentId`, which is correct because every
##    duplicated item measured is a leaf that nothing parents to.
## 3. **`startingRoubles` still means what it says.** The template already
##    carries 500,000 roubles in two stacks. Rather than appending a stack --
##    which would make the item count disagree with the template it was seeded
##    from, and make the acceptance check unfalsifiable -- the FIRST rouble
##    stack is resized so the total matches the setting.

import std/strutils
import aowlspt/server
import aowlspt/json
import ids

const
  Roubles = "5449016a4bdc2d6f028b456f"

  RootKeys = ["equipment", "stash", "questRaidItems", "questStashItems",
              "sortingTable", "hideoutCustomizationStashId"]

type
  StarterKit* = object
    ok*: bool
    reason*: string       ## why not, when `ok` is false
    editionKey*: string   ## the SPT table key that was used
    inventory*: string    ## raw JSON for `Inventory`
    encyclopedia*: string ## raw JSON for `Encyclopedia`
    bonuses*: string      ## raw JSON for `Bonuses`
    trader*: string       ## raw JSON for the edition's `trader` block
    itemCount*: int
    stashId*: string
    equipmentId*: string

# ---------------------------------------------------------------------------
# Editions
# ---------------------------------------------------------------------------
#
# Three spellings of the same thing are already in flight and none of them can
# be dropped: the settings page offers hyphens (`edge-of-darkness`), the
# launcher and `Info.GameVersion` use underscores (`edge_of_darkness`), and
# SPT's table is keyed by display name (`Edge Of Darkness`). `normalEdition`
# folds the first two together; `EditionKey`/`EditionTable` map to the third.

const
  EditionKey = ["standard", "left_behind", "prepare_for_escape",
                "edge_of_darkness", "unheard_edition"]
  EditionTable = ["Standard", "Left Behind", "Prepare To Escape",
                  "Edge Of Darkness", "Unheard"]

proc normalEdition*(edition: string): string =
  ## The canonical `Info.GameVersion` spelling, or "" when the edition is not
  ## one this server can build a profile for. Empty is a REFUSAL, and the
  ## launcher route turns it into one -- silently downgrading to standard is
  ## the failure mode this whole module exists to remove.
  var e = toLowerAscii(edition)
  var fixed = ""
  for i in 0 ..< e.len:
    if e[i] == '-' or e[i] == ' ': fixed.add '_'
    else: fixed.add e[i]
  # A couple of spellings seen on the wire that are not the canonical one.
  if fixed == "prepare_to_escape": fixed = "prepare_for_escape"
  if fixed == "unheard": fixed = "unheard_edition"
  if fixed == "eod": fixed = "edge_of_darkness"
  for k in EditionKey:
    if k == fixed:
      return fixed
  result = ""

proc editionTableKey*(edition: string): string =
  ## SPT's display-name key for a canonical edition, or "".
  let e = normalEdition(edition)
  for i in 0 ..< EditionKey.len:
    if EditionKey[i] == e:
      return EditionTable[i]
  result = ""

proc knownEditions*(): seq[string] =
  result = @[]
  for k in EditionKey: result.add k

# ---------------------------------------------------------------------------
# Id remapping
# ---------------------------------------------------------------------------

proc lookup(olds, news: seq[string]; id: string): string =
  for i in 0 ..< olds.len:
    if olds[i] == id:
      return news[i]
  result = ""

proc stackCount(itemRaw: string): int =
  ## `upd.StackObjectsCount`, or 1 when the item has no `upd`.
  let u = field(itemRaw, "upd.StackObjectsCount")
  if exists(u): return asInt(u, 1)
  result = 1

# ---------------------------------------------------------------------------

proc starterKit*(edition, sideName: string; startingRoubles: int): StarterKit =
  ## The starting kit for an edition and a side, with fresh ids.
  result = StarterKit(ok: false, reason: "", editionKey: "", inventory: "",
                      encyclopedia: "", bonuses: "", trader: "",
                      itemCount: 0, stashId: "", equipmentId: "")
  let tableKey = editionTableKey(edition)
  if tableKey.len == 0:
    result.reason = "no starting-gear template is known for edition '" &
                    edition & "'"
    return
  result.editionKey = tableKey
  let side = if toLowerAscii(sideName) == "bear": "bear" else: "usec"
  let base = "templates.profiles." & tableKey & "." & side
  let ch = dbRead(base & ".character")
  if not ch.ok or ch.raw.len == 0:
    result.reason = "the database has no templates.profiles." & tableKey &
                    "." & side & ".character -- re-run `aowl importdb` " &
                    "against an SPT install to import templates/profiles.json"
    return

  let inv = field(ch.raw, "Inventory")
  let itemsJ = field(inv, "items")
  if not isArray(itemsJ):
    result.reason = "templates.profiles." & tableKey & "." & side &
                    ".character.Inventory.items is not an array"
    return
  let items = parseArray(itemsJ)
  if items.len == 0:
    result.reason = "the starting-gear template for " & tableKey & "/" &
                    side & " has no items"
    return

  # Pass 1 -- a fresh id per OCCURRENCE, and a first-occurrence-wins map for
  # resolving parents. See rule 2 in the header.
  var olds: seq[string] = @[]
  var news: seq[string] = @[]
  var fresh: seq[string] = @[]
  for i in 0 ..< items.len:
    let old = field(items.items[i], "_id").asText("")
    let nid = newId()
    fresh.add nid
    if old.len > 0 and lookup(olds, news, old).len == 0:
      olds.add old
      news.add nid

  # The rouble stacks, so `startingRoubles` can be honoured without changing
  # the item count. `firstMoney` is an index into `items`.
  var firstMoney = -1
  var otherRoubles = 0
  for i in 0 ..< items.len:
    if field(items.items[i], "_tpl").asText("") == Roubles:
      if firstMoney < 0: firstMoney = i
      else: otherRoubles = otherRoubles + stackCount(items.items[i])

  # Pass 2 -- rebuild each item with its new id and remapped parent. Every
  # other member is copied as the raw text it was, so nothing this emulator
  # does not understand is dropped.
  var outItems = newList()
  for i in 0 ..< items.len:
    var d = parseObject(items.items[i])
    if not d.ok:
      result.reason = "item " & $i & " of the starting-gear template is not " &
                      "a JSON object"
      return
    setText(d, "_id", fresh[i])
    if has(d, "parentId"):
      let p = get(d, "parentId").asText("")
      let np = lookup(olds, news, p)
      if np.len > 0:
        setText(d, "parentId", np)
    if i == firstMoney:
      var want = startingRoubles - otherRoubles
      if want < 0: want = 0
      setRaw(d, "upd", "{\"StackObjectsCount\":" & $want & "}")
    outItems.add text(d)

  # The inventory's own roots. Everything that is an id gets remapped;
  # everything else is copied verbatim.
  var invDoc = parseObject(inv)
  if not invDoc.ok:
    result.reason = "the starting-gear template's Inventory is not an object"
    return
  for k in RootKeys:
    if has(invDoc, k):
      let old = get(invDoc, k).asText("")
      let nid = lookup(olds, news, old)
      if nid.len > 0:
        setText(invDoc, k, nid)
  # `fastPanel` is slot -> item id.
  if has(invDoc, "fastPanel"):
    let fp = get(invDoc, "fastPanel")
    if isObject(fp):
      var fpDoc = parseObject(fp)
      var slotNames: seq[string] = @[]
      var slotIds: seq[string] = @[]
      for m in fpDoc.fields:
        slotNames.add m.name
        slotIds.add asText(whole(m.value), "")
      for i in 0 ..< slotNames.len:
        let nid = lookup(olds, news, slotIds[i])
        if nid.len > 0:
          setText(fpDoc, slotNames[i], nid)
      setRaw(invDoc, "fastPanel", text(fpDoc))
  setRaw(invDoc, "items", text(outItems))

  result.inventory = text(invDoc)
  result.itemCount = outItems.len
  result.stashId = get(invDoc, "stash").asText("")
  result.equipmentId = get(invDoc, "equipment").asText("")

  let enc = field(ch.raw, "Encyclopedia")
  result.encyclopedia = if isObject(enc): enc.raw() else: "{}"
  let bon = field(ch.raw, "Bonuses")
  result.bonuses = if isArray(bon): bon.raw() else: "[]"
  let tr = dbRead(base & ".trader")
  result.trader = if tr.ok and tr.raw.len > 0: tr.raw else: "{}"
  result.ok = true

# ---------------------------------------------------------------------------
# TradersInfo
# ---------------------------------------------------------------------------

proc seedTradersInfo*(traderBlock: string): string =
  ## What a fresh profile knows about each trader.
  ##
  ## This used to be `{}` on every new profile, which is not "no reputation
  ## yet": the read path fabricates `unlocked: true` for a trader with no
  ## entry, so Jaeger -- who is locked until his quest is done -- was open from
  ## minute one, and every trader's standing did not exist until something was
  ## sold.
  ##
  ## Seeded from the edition's `trader` block: `initialLoyaltyLevel` per trader,
  ## `initialStanding` (with a `default`), `initialSalesSum`, `jaegerUnlocked`
  ## and `lockedByDefaultOverride` -- the last being the traders that start
  ## locked whatever their loyalty level says.
  ##
  ## The trader LIST still comes from the database, so a server whose database
  ## has no traders writes no entries rather than entries for traders that do
  ## not exist.
  const Jaeger = "5c0647fdd443bc2504c2d371"
  let tb = if traderBlock.len > 0: traderBlock else: "{}"
  var o = obj()
  let all = dbRead("traders")
  if not all.ok or all.raw.len == 0:
    return done(o).text
  let ids = keys(whole(all.raw))
  let loyal = field(tb, "initialLoyaltyLevel")
  let standing = field(tb, "initialStanding")
  let salesSum = asInt(field(tb, "initialSalesSum"), 0)
  let jaegerUnlocked = asBool(field(tb, "jaegerUnlocked"), false)
  var lockedByDefault: seq[string] = @[]
  let lockList = field(tb, "lockedByDefaultOverride")
  if isArray(lockList):
    for e in each(lockList):
      lockedByDefault.add asText(e, "")
  let defaultStanding = asFloat(child(standing, "default"), 0.0)
  for id in ids:
    var t = obj()
    put(t, "loyaltyLevel", asInt(child(loyal, id), 1))
    put(t, "salesSum", salesSum)
    put(t, "standing", asFloat(child(standing, id), defaultStanding))
    put(t, "nextResupply", 0)
    var unlocked = true
    if id == Jaeger:
      unlocked = jaegerUnlocked
    for l in lockedByDefault:
      if l == id: unlocked = false
    put(t, "unlocked", unlocked)
    put(t, "disabled", false)
    put(o, id, t)
  result = done(o).text
