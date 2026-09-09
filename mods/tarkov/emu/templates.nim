## The static tables: items, globals, the handbook, locales, customization.
##
## All of it comes out of the loaded database through `dbRead`, and every one of
## these has a fallback for when the database does not have it.
##
## The fallback is the interesting part. A server that only works with a full
## live database dump present cannot be tested, cannot be started for the first
## time, and gives a new user a wall of errors instead of a menu. So each table
## answers with what it has: the real thing if the database holds it, a valid
## empty table if not. The client renders an empty flea market; it does not fail
## to reach the menu.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

proc table*(path: string; fallback: string): string =
  ## A database subtree as raw JSON, or `fallback` when the database does not
  ## have it. Returned as text and spliced into the response without being
  ## parsed -- these are the largest bodies the server sends and there is
  ## nothing in them it needs to look at.
  let v = dbRead(path)
  if v.ok and v.raw.len > 0:
    return v.raw
  result = fallback

proc items*(): string = table("templates.items", "{}")
proc globals*(): string = table("globals", "{}")
proc handbook*(): string =
  ## Two arrays the client indexes by, so both must exist even when empty --
  ## a missing `Items` is a null dereference in the handbook screen.
  let v = dbRead("templates.handbook")
  if v.ok and v.raw.len > 0:
    return v.raw
  var h = obj()
  put(h, "Categories", arr())
  put(h, "Items", arr())
  result = done(h).text

proc customization*(): string = table("templates.customization", "{}")
proc quests*(): string = table("templates.quests", "{}")

var gQuestArray = ""
var gQuestArrayBuilt = false

proc questList*(): string =
  ## The quest templates as an **array**, which is what `/client/quest/list`
  ## answers with.
  ##
  ## `templates.quests` is stored keyed by quest id, because every other reader
  ## of it wants a lookup. The client does not: the real backend sends a bare
  ## array (capture seq 130, 262, 444), and an object where an array is
  ## expected deserialises to nothing, which is a quest journal with no quests
  ## in it and no error anywhere.
  ##
  ## Built once. It is half a megabyte, it does not change while the server is
  ## up, and it is asked for on every menu load.
  if gQuestArrayBuilt:
    return gQuestArray
  gQuestArrayBuilt = true
  # Not named `raw`: that is a proc in `aowlspt/server`, used two lines below
  # to splice a member in without reparsing it, and a local of the same name
  # shadows it.
  let stored = quests()
  let doc = whole(stored)
  if not isObject(doc):
    # Already an array, or absent. Passed through: a database that stores this
    # the way the client wants it is not a case to correct.
    gQuestArray = if stored.len > 0: stored else: "[]"
    return gQuestArray
  var a = arr()
  let ms = members(doc)
  for m in ms:
    a.add raw(m.value)
  gQuestArray = done(a).text
  result = gQuestArray

proc achievements*(): string = table("templates.achievements", "[]")
proc locations*(): string = table("locations", "{}")

proc locale*(language: string): string =
  ## The client asks for a language and expects a flat id -> text map. Falling
  ## back to English rather than to nothing, because an empty locale renders
  ## every item name as its template id.
  let v = dbRead("locales.global." & language)
  if v.ok and v.raw.len > 0:
    return v.raw
  let en = dbRead("locales.global.en")
  if en.ok and en.raw.len > 0:
    return en.raw
  result = "{}"

proc menuLocale*(language: string): string =
  let v = dbRead("locales.menu." & language)
  if v.ok and v.raw.len > 0:
    return v.raw
  let en = dbRead("locales.menu.en")
  if en.ok and en.raw.len > 0:
    return en.raw
  result = "{}"

proc languages*(): string =
  ## What the client offers in its language dropdown. Derived from the locales
  ## the database actually has, so the dropdown cannot offer a language that
  ## would then come back empty.
  let v = dbRead("locales.languages")
  if v.ok and v.raw.len > 0:
    return v.raw
  let globals = dbRead("locales.global")
  var o = obj()
  if globals.ok:
    let names = keys(whole(globals.raw))
    for n in names:
      put(o, n, n)
  if o.len == 0:
    put(o, "en", "English")
  result = done(o).text

proc itemExists*(tpl: string): bool =
  let v = dbRead("templates.items." & tpl & "._id")
  result = v.ok

proc itemProp*(tpl, prop: string): DbValue =
  result = dbRead("templates.items." & tpl & "._props." & prop)

proc itemSize*(tpl: string; width, height: var int) =
  ## A template's grid footprint, defaulting to 1x1. Every inventory operation
  ## needs this, and an item the database does not have still has to be placed
  ## somewhere rather than rejected -- the client already drew it.
  width = 1
  height = 1
  let w = itemProp(tpl, "Width")
  let h = itemProp(tpl, "Height")
  if w.ok: width = w.asInt(1)
  if h.ok: height = h.asInt(1)
  if width < 1: width = 1
  if height < 1: height = 1

proc itemStackLimit*(tpl: string): int =
  ## The stack limit, or **zero for "not known"**.
  ##
  ## Zero rather than one, and that distinction is the whole point. A template
  ## the database does not have is not a template with a limit of one -- and
  ## treating it as one makes every merge of a stack the server has no data for
  ## fail, which on a server started without an item table is every merge there
  ## is. The caller enforces a limit it was given and lets an unknown one pass.
  let v = itemProp(tpl, "StackMaxSize")
  if not v.ok:
    return 0
  result = v.asInt(0)
  if result < 0: result = 0

proc handbookPrice*(tpl: string): int =
  ## What the handbook says an item is worth, or zero when it says nothing.
  ##
  ## Zero is a refusal, not a price. A caller that pays it would let a player
  ## sell a rifle for nothing on a server whose database has no handbook -- and
  ## the item is gone either way, so "I do not know what this is worth" has to
  ## be a different answer from "it is worth nothing".
  result = 0
  let hb = dbRead("templates.handbook.Items")
  if not hb.ok:
    return
  let list = each(whole(hb.raw))
  for entry in list:
    if entry.field("Id").asText("") == tpl:
      return entry.field("Price").asInt(0)

proc handbookCategories*(tpl: string): seq[string] =
  ## Every handbook category an item is in: the one its entry names, then that
  ## category's parent, and so on to the root of the tree.
  ##
  ## Empty when the handbook has no entry for the template, and the caller must
  ## be able to tell that from "in no excluded category" -- the two are the same
  ## list and they are not the same fact. `traderRefuses` in `emu/repair` treats
  ## an item the handbook does not place as one it cannot judge, and repairs it,
  ## which is the forgiving direction and is named there.
  ##
  ## The walk is what makes an exclusion mean anything. A trader's
  ## `excluded_category` names a *branch* -- "Gear", "Weapons" -- and an item
  ## sits several levels below it, so matching only the category the item's own
  ## entry names refuses nothing at all on real data, where the leaf categories
  ## are the ones items are filed under and the named ones are three levels up.
  ##
  ## Bounded by the size of the category table, because `ParentId` is data: a
  ## handbook with a loop in it must return a list rather than spin.
  result = @[]
  let hb = dbRead("templates.handbook")
  if not hb.ok or hb.raw.len == 0:
    return
  var current = ""
  let items = each(field(hb.raw, "Items"))
  for entry in items:
    if entry.field("Id").asText("") == tpl:
      current = entry.field("ParentId").asText("")
      break
  if current.len == 0:
    return
  let cats = each(field(hb.raw, "Categories"))
  var steps = 0
  while current.len > 0 and steps <= cats.len:
    result.add current
    var next = ""
    for c in cats:
      if c.field("Id").asText("") == current:
        next = c.field("ParentId").asText("")
        break
    if next == current:
      # A category that is its own parent. One entry, not an infinite tree.
      return
    current = next
    inc steps
# ---------------------------------------------------------------------------
# Container roots that must never be posted as mail
# ---------------------------------------------------------------------------
#
# A stash is a *container the player owns*, not cargo. It reached the mailbox
# because `EFT.TransferItemsController` keys its containers by profile id and
# the container it hands back IS a `Stash` -- `TryGetTransferContainer(string
# profileId, Stash)` -- so a `transferItems` body serialises the container's
# own root item alongside whatever was inside it. Posting the root posts a
# single item named "Stash" with no icon, and hides the actual cargo under it.
#
# MEASURED in the live mailbox on 2026-08-28, `store\aowl.tarkov\
# mail.00000000000a00000000004f`: one message, `hasRewards: true`, exactly one
# attachment, `_tpl 566abbc34bdc2d92178b4576` = "Standard stash 10x30", and an
# `_id` (`656f0f98d80a697f855d34b1`) that is in NO profile item list -- so it
# was the client's transfer container, not the player's own stash.
#
# MEASURED in `db.json`: `566abbb64bdc2d144c8b457d` is the node named "Stash",
# and exactly nine templates hang off it.

const StashNodeTpl* = "566abbb64bdc2d144c8b457d"
  ## The "Stash" node in `templates.items`. MEASURED from `db.json`.

const KnownStashTpls* = [
  "566abbc34bdc2d92178b4576",  # Standard stash 10x30
  "5811ce572459770cba1a34ea",  # Left Behind stash 10x40
  "5811ce662459770f6f490f32",  # Prepare for escape stash 10x50
  "5811ce772459770e9e5f9532",  # Edge of darkness stash 10x68
  "5963866286f7747bf429b572",  # stash 8x6
  "5963866b86f7747bfa1c4462",  # stash 8x40
  "5c0a596086f7747bef5731c2",  # stash 10x300
  "6602bcf19cc643f44a04274b",  # The Unheard Edition stash 10x72
  "6050cac987d3f925bf016837",  # SortingTable (a Node, but the same shape)
  StashNodeTpl]
  ## The nine children of the Stash node plus the node itself, MEASURED from
  ## `db.json` on 2026-08-28.
  ##
  ## Listed rather than only walked, on purpose. `isStashTpl` must give the
  ## right answer with **no database loaded at all** -- `emutest` runs against
  ## a small staged fixture, and a check that silently passes because the
  ## database it consults is empty is exactly the shape CLAUDE.md 9b forbids.

proc isStashTpl*(tpl: string): bool =
  ## Is this template a stash / player container root?
  ##
  ## Two independent signals, either sufficient: the measured list above, and a
  ## walk up `_parent` to the Stash node for anything a mod or a newer database
  ## adds. The walk is capped -- a database with a parent cycle must return
  ## false, not hang the mailbox.
  if tpl.len == 0:
    return false
  for k in KnownStashTpls:
    if k == tpl:
      return true
  var current = tpl
  var steps = 0
  while current.len > 0 and steps < 16:
    let v = dbRead("templates.items." & current & "._parent")
    if not v.ok:
      return false
    let parent = whole(v.raw).asText("")
    if parent.len == 0:
      return false
    if parent == StashNodeTpl:
      return true
    if parent == current:
      return false
    current = parent
    inc steps
  result = false
