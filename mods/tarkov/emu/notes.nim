## Notes and map markers.
##
## Six item events -- `AddNote`, `EditNote`, `DeleteNote`, `CreateMapMarker`,
## `EditMapMarker`, `DeleteMapMarker` -- and two pieces of state, which is why
## they share a module rather than a home:
##
## - a **note** is the profile's, at `Notes.Notes`, a list of
##   `{Time, Text}` (the reference's `Note`);
## - a **marker** is an *item's*, at `upd.Map.Markers`, a list of
##   `{Note, Type, X, Y}` (the reference's `UpdMap` and `MapMarker`) -- because
##   a marker is drawn on a particular paper map in the player's stash, and
##   selling that map sells the marks on it.
##
## Both were unhandled actions, and both fail the same quiet way the heal did:
## the client writes the note into its own copy the moment it is typed, so the
## player sees it, plays on, and finds it gone the next time the server hands
## back a profile. Nothing errors at either end.
##
## ## What is checked
##
## An `EditNote` or a `DeleteNote` names an **index** into a list the server
## holds, and an index the list does not have is refused rather than clamped:
## clamping edits the wrong note, which is worse than refusing, and the client
## resends from a list it just read.
##
## A marker names the item it belongs to, and an item the player does not own
## is refused -- a marker written onto an id that is not in the inventory is a
## write into nothing that succeeds.
##
## `_props.MaxMarkersCount` is the map's own limit and is enforced when the
## database has it. The reference gives **no** limit on the length of a note's
## text or on the number of notes a profile may hold; both are bounded here
## anyway, by the two constants below, because the profile is read and written
## whole on every request and an unbounded list in it is a profile that gets
## slower forever. The bounds are this server's and are named as such.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import numbers
import profile
import inventory
import templates

const
  MaxNotes* = 256
    ## This server's bound on `Notes.Notes`, not the reference's -- see above.
  MaxNoteText* = 512
    ## Likewise. Refused rather than truncated: a note silently cut in half is
    ## a note the player has to retype without being told why.
  MaxMarkersFallback* = 64
    ## Used only when the map's template does not carry `MaxMarkersCount`, which
    ## is every map on a server with no item table.

type
  NoteAction* = enum
    naNone, naNoteAdd, naNoteEdit, naNoteDelete,
    naMarkerCreate, naMarkerEdit, naMarkerDelete

proc noteAction*(name: string): NoteAction =
  case name
  of "AddNote": naNoteAdd
  of "EditNote": naNoteEdit
  of "DeleteNote": naNoteDelete
  of "CreateMapMarker": naMarkerCreate
  of "EditMapMarker": naMarkerEdit
  of "DeleteMapMarker": naMarkerDelete
  else: naNone

# ---------------------------------------------------------------------------
# Notes
# ---------------------------------------------------------------------------

proc noteList(p: Profile): List =
  result = parseArray(p.field("Notes.Notes").raw())
  if not result.ok:
    result = newList()

proc putNotes(p: var Profile; list: List) =
  ## `Notes` is `{Notes: [...]}` -- an object wrapping the list, not the list.
  ## Written through `setTopLevel` so a profile created before this module
  ## existed grows the member rather than dropping the write on the floor.
  var wrapper = parseObject(p.field("Notes").raw())
  if not wrapper.ok:
    wrapper = newDoc()
  setRaw(wrapper, "Notes", text(list))
  p.setTopLevel("Notes", text(wrapper))

proc noteFrom(action: JsonRef; nowSeconds: int; text1: var string;
              time: var int): bool =
  var node = action.field("note")
  if not node.found:
    node = action.field("Note")
  if not node.found:
    return false
  text1 = node.field("Text").asText(node.field("text").asText(""))
  # `Time` is the client's own timestamp and is taken when it sends one --
  # a note is the player's record of when they wrote it, not of when the
  # request arrived. Stamped here only when the body has none.
  time = node.field("Time").asInt(node.field("time").asInt(nowSeconds))
  result = true

proc noteIndex(action: JsonRef): int =
  let a = action.field("index")
  if a.found:
    return a.asInt(-1)
  result = action.field("Index").asInt(-1)

proc doNoteAdd(p: var Profile; action: JsonRef; nowSeconds: int;
               ch: var Change): bool =
  var body = ""
  var time = nowSeconds
  if not noteFrom(action, nowSeconds, body, time):
    ch.problems.add "note: the request carried no note"
    return false
  if body.len == 0:
    ch.problems.add "note: an empty note is not a note"
    return false
  if body.len > MaxNoteText:
    ch.problems.add "note: that note is " & $body.len &
                    " characters and the limit here is " & $MaxNoteText
    return false
  var list = noteList(p)
  if list.len >= MaxNotes:
    ch.problems.add "note: this profile already holds " & $MaxNotes & " notes"
    return false
  var d = newDoc()
  setNumber(d, "Time", time)
  setText(d, "Text", body)
  list.add d
  putNotes(p, list)
  result = true

proc doNoteEdit(p: var Profile; action: JsonRef; nowSeconds: int;
                ch: var Change): bool =
  let at = noteIndex(action)
  var list = noteList(p)
  if at < 0 or at >= list.len:
    ch.problems.add "note: there is no note " & $at
    return false
  var body = ""
  var time = nowSeconds
  if not noteFrom(action, nowSeconds, body, time):
    ch.problems.add "note: the request carried no note"
    return false
  if body.len == 0 or body.len > MaxNoteText:
    ch.problems.add "note: that note is not a length this server keeps"
    return false
  var d = newDoc()
  setNumber(d, "Time", time)
  setText(d, "Text", body)
  list.replaceAt(at, text(d))
  putNotes(p, list)
  result = true

proc doNoteDelete(p: var Profile; action: JsonRef; ch: var Change): bool =
  let at = noteIndex(action)
  var list = noteList(p)
  if at < 0 or at >= list.len:
    ch.problems.add "note: there is no note " & $at
    return false
  list.removeAt(at)
  putNotes(p, list)
  result = true

# ---------------------------------------------------------------------------
# Map markers
# ---------------------------------------------------------------------------

proc markerCoords(node: JsonRef; x, y: var float): bool =
  ## `X`/`Y` on the request or on its `mapMarker`. Read as floats because the
  ## reference has them `Nullable<Double>` on the edit request and
  ## `Nullable<Int32>` on the delete one, so a marker placed at 12.5 must not
  ## become a marker at 12 that the delete then cannot find.
  let xa = node.field("X")
  let ya = node.field("Y")
  if not xa.found or not ya.found:
    return false
  x = xa.asFloat(0.0)
  y = ya.asFloat(0.0)
  result = true

proc markerOf(action: JsonRef): JsonRef =
  var node = action.field("mapMarker")
  if not node.found:
    node = action.field("MapMarker")
  result = node

proc mapItem(inv: Inventory; action: JsonRef; ch: var Change;
             index: var int): bool =
  index = -1
  let id = action.field("item").asText(action.field("Item").asText(""))
  if id.len == 0:
    ch.problems.add "marker: no map named"
    return false
  index = indexOf(inv, id)
  if index < 0:
    ch.problems.add "marker: no such item " & id
    return false
  result = true

proc markers(item: Doc): List =
  let upd = get(item, "upd")
  if not upd.found:
    return newList()
  let m = upd.field("Map").field("Markers")
  if not m.found:
    return newList()
  result = parseArray(m)
  if not result.ok:
    result = newList()

proc putMarkers(item: var Doc; list: List) =
  var upd = parseObject(getRaw(item, "upd"))
  if not upd.ok:
    upd = newDoc()
  var m = parseObject(getRaw(upd, "Map"))
  if not m.ok:
    m = newDoc()
  setRaw(m, "Markers", text(list))
  setRaw(upd, "Map", text(m))
  setRaw(item, "upd", text(upd))

proc markerAt(list: List; x, y: float): int =
  result = -1
  for i in 0 ..< list.len:
    let e = whole(list.items[i])
    if e.field("X").asFloat(0.0) == x and e.field("Y").asFloat(0.0) == y:
      return i

proc markerLimit(tpl: string): int =
  let v = itemProp(tpl, "MaxMarkersCount")
  if not v.ok:
    return MaxMarkersFallback
  result = v.asInt(MaxMarkersFallback)
  if result <= 0:
    result = MaxMarkersFallback

proc doMarkerCreate(inv: var Inventory; action: JsonRef;
                    ch: var Change): bool =
  var at = -1
  if not mapItem(inv, action, ch, at):
    return false
  let node = markerOf(action)
  if not node.found:
    ch.problems.add "marker: the request carried no marker"
    return false
  var x = 0.0
  var y = 0.0
  if not markerCoords(node, x, y):
    ch.problems.add "marker: that marker has no position"
    return false
  let note = node.field("Note").asText("")
  if note.len > MaxNoteText:
    ch.problems.add "marker: that note is longer than this server keeps"
    return false
  var item = itemAt(inv, at)
  let tpl = get(item, "_tpl").asText("")
  var list = markers(item)
  if markerAt(list, x, y) >= 0:
    # The client draws one marker per cell, so a second one at the same place
    # is either a replayed request or a stale screen; either way it would be a
    # marker the player can see once and delete twice.
    ch.problems.add "marker: there is already a marker there"
    return false
  let limit = markerLimit(tpl)
  if list.len >= limit:
    ch.problems.add "marker: that map holds " & $limit & " markers"
    return false
  var d = newDoc()
  setRaw(d, "X", node.field("X").raw())
  setRaw(d, "Y", node.field("Y").raw())
  setText(d, "Note", note)
  setText(d, "Type", node.field("Type").asText(""))
  list.add d
  putMarkers(item, list)
  inv.items.replaceAt(at, text(item))
  inv.dirty = true
  ch.changed.add text(item)
  result = true

proc doMarkerEdit(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  ## The marker being edited is named by its **old** position, on the request
  ## itself; the new one is inside `mapMarker`. That is the reference's shape --
  ## `InventoryEditMarkerRequestData` carries `X`, `Y` *and* a `MapMarker` --
  ## and reading the position off the wrong one moves a marker the player did
  ## not touch.
  var at = -1
  if not mapItem(inv, action, ch, at):
    return false
  var oldX = 0.0
  var oldY = 0.0
  if not markerCoords(action, oldX, oldY):
    ch.problems.add "marker: the request did not say which marker"
    return false
  let node = markerOf(action)
  if not node.found:
    ch.problems.add "marker: the request carried no marker"
    return false
  var item = itemAt(inv, at)
  var list = markers(item)
  let index = markerAt(list, oldX, oldY)
  if index < 0:
    ch.problems.add "marker: there is no marker there"
    return false
  let note = node.field("Note").asText("")
  if note.len > MaxNoteText:
    ch.problems.add "marker: that note is longer than this server keeps"
    return false
  var d = newDoc()
  var newX = oldX
  var newY = oldY
  discard markerCoords(node, newX, newY)
  if newX != oldX or newY != oldY:
    if markerAt(list, newX, newY) >= 0:
      ch.problems.add "marker: there is already a marker there"
      return false
  setRaw(d, "X", numText(newX))
  setRaw(d, "Y", numText(newY))
  setText(d, "Note", note)
  setText(d, "Type", node.field("Type").asText(""))
  list.replaceAt(index, text(d))
  putMarkers(item, list)
  inv.items.replaceAt(at, text(item))
  inv.dirty = true
  ch.changed.add text(item)
  result = true

proc doMarkerDelete(inv: var Inventory; action: JsonRef; ch: var Change): bool =
  var at = -1
  if not mapItem(inv, action, ch, at):
    return false
  var x = 0.0
  var y = 0.0
  if not markerCoords(action, x, y):
    ch.problems.add "marker: the request did not say which marker"
    return false
  var item = itemAt(inv, at)
  var list = markers(item)
  let index = markerAt(list, x, y)
  if index < 0:
    ch.problems.add "marker: there is no marker there"
    return false
  list.removeAt(index)
  putMarkers(item, list)
  inv.items.replaceAt(at, text(item))
  inv.dirty = true
  ch.changed.add text(item)
  result = true

# ---------------------------------------------------------------------------

proc applyNotes*(p: var Profile; inv: var Inventory; kind: NoteAction;
                 action: JsonRef; nowSeconds: int; ch: var Change): bool =
  ## Returns whether the *profile* changed. The three marker arms change items
  ## and say so through `inv.dirty`, exactly as `PinLock` does.
  case kind
  of naNoteAdd: result = doNoteAdd(p, action, nowSeconds, ch)
  of naNoteEdit: result = doNoteEdit(p, action, nowSeconds, ch)
  of naNoteDelete: result = doNoteDelete(p, action, ch)
  of naMarkerCreate:
    discard doMarkerCreate(inv, action, ch)
    result = false
  of naMarkerEdit:
    discard doMarkerEdit(inv, action, ch)
    result = false
  of naMarkerDelete:
    discard doMarkerDelete(inv, action, ch)
    result = false
  of naNone: result = false
