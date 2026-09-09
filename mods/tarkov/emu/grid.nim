## Finding somewhere to put an item.
##
## Anything the server gives a player — bought from a trader, returned by
## insurance, attached to a message — has to land in a real cell of the stash,
## with a position and a rotation. There is no "just put it in the container":
## the client draws the stash from the positions the server sent, and an item
## with no location, or one overlapping another item, is drawn on top of what is
## already there and cannot be picked up.
##
## So: an occupancy map of the grid, and a scan for the first rectangle that
## fits. First-fit from the top-left, which is what the game's own "sort" does,
## and both orientations tried because a 1x4 rifle that does not fit vertically
## usually fits across.
##
## The grid's size comes from the stash template when the database has one and
## falls back to 10x68 — the standard-edition stash — when it does not. A server
## with no item table still has to be able to hand someone a gun.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import templates

const
  DefaultWidth* = 10
  DefaultHeight* = 68

type
  Grid* = object
    width*: int
    height*: int
    cells: seq[bool]

  Placement* = object
    ok*: bool
    x*: int
    y*: int
    rotated*: bool

proc newGrid*(width, height: int): Grid =
  var w = width
  var h = height
  if w < 1: w = DefaultWidth
  if h < 1: h = DefaultHeight
  result = Grid(width: w, height: h, cells: newSeq[bool](w * h))

proc stashGrid*(stashTpl: string): Grid =
  ## The stash's dimensions out of its template's first grid.
  let props = dbRead("templates.items." & stashTpl & "._props.Grids")
  if not props.ok:
    return newGrid(DefaultWidth, DefaultHeight)
  let first = at(whole(props.raw), 0)
  if not first.found:
    return newGrid(DefaultWidth, DefaultHeight)
  let w = first.field("_props.cellsH").asInt(DefaultWidth)
  let h = first.field("_props.cellsV").asInt(DefaultHeight)
  result = newGrid(w, h)

proc occupy*(g: var Grid; x, y, w, h: int) =
  var ry = y
  while ry < y + h:
    var rx = x
    while rx < x + w:
      if rx >= 0 and ry >= 0 and rx < g.width and ry < g.height:
        g.cells[ry * g.width + rx] = true
      inc rx
    inc ry

proc fits(g: Grid; x, y, w, h: int): bool =
  if x < 0 or y < 0 or x + w > g.width or y + h > g.height:
    return false
  var ry = y
  while ry < y + h:
    var rx = x
    while rx < x + w:
      if g.cells[ry * g.width + rx]:
        return false
      inc rx
    inc ry
  result = true

proc markOccupied*(g: var Grid; itemsJson, containerId: string) =
  ## Fills the map from what is already in the container. Only direct children
  ## with a location: something inside a rig inside the stash occupies cells in
  ## the rig, not in the stash, and counting it here would slowly fill a stash
  ## that is actually empty.
  let list = parseArray(itemsJson)
  if not list.ok:
    return
  for i in 0 ..< list.len:
    let it = whole(list.items[i])
    if it.field("parentId").asText("") != containerId:
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

proc findSpace*(g: Grid; tpl: string): Placement =
  ## First fit, upright then rotated. Returns `ok: false` when the container is
  ## full, which the caller must treat as a refusal rather than dropping the
  ## item at 0,0 -- an overlapping item is worse than an item the player was
  ## told they had no room for.
  result = Placement(ok: false, x: 0, y: 0, rotated: false)
  var w = 1
  var h = 1
  itemSize(tpl, w, h)

  var y = 0
  while y < g.height:
    var x = 0
    while x < g.width:
      if fits(g, x, y, w, h):
        return Placement(ok: true, x: x, y: y, rotated: false)
      inc x
    inc y

  if w == h:
    return
  y = 0
  while y < g.height:
    var x = 0
    while x < g.width:
      if fits(g, x, y, h, w):
        return Placement(ok: true, x: x, y: y, rotated: true)
      inc x
    inc y

proc locationJson*(p: Placement): string =
  var o = obj()
  put(o, "x", p.x)
  put(o, "y", p.y)
  # An integer, not the name: post-1.0 deserialises `location.r` into the
  # `ItemRotation` enum from the number the real backend sends (`0`/`1`), and a
  # profile-changes item the client cannot place is a purchase that spins
  # forever. `markOccupied` above already reads either form.
  put(o, "r", if p.rotated: 1 else: 0)
  result = done(o).text
