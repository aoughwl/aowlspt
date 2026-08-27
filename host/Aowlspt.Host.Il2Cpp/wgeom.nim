# wgeom.nim -- THE WIDGET MODEL AND ITS PURE GEOMETRY.
#
# `include`d into `debugui.nim`, and ALSO into `tests/wgeom_test.nim`.
#
# EVERYTHING IN THIS FILE IS PURE. No managed call, no IL2CPP pointer, no
# Windows call, no global the game writes. That is a hard constraint on what may
# be added here, and it exists for one reason: it is the only way to exercise
# the placement, snap and clamp paths WITHOUT a running client.
#
# The overlay's first live run faulted on its first refresh and self-disabled
# after eight faults, showing the user nothing. Nothing about that could be
# reproduced offline, because the arithmetic was tangled up with the managed
# draw calls in one proc. Split this way, `tests/wgeom_test.nim` can drive every
# built-in placement against a 0x0 back buffer (the state before the region
# publishes a size) and against 3840x2160, and assert on the FINISHED STATE --
# every widget on screen, no NaN, no infinity -- rather than on its own writes.
#
# If you add a proc here that calls into the game, the test stops compiling.
# That is the intended failure mode.

const
  cDuMaxWidgets   = 12    ## hard ceiling; the label pool is built at this size
  cDuMaxWidgetLines = 14  ## lines rendered into ONE widget label
  cDuSnapPx       = 14.0  ## canvas units within which a snap engages
  cDuSnapMargin   = 12.0  ## resting distance from a screen edge after a snap
  cDuSnapGap      = 4.0   ## resting gap when a widget snaps to another widget

type DuWidget = object
  id: string            ## stable key: the config and the layout file use it
  title: string         ## header line; "" draws no header
  fields: string        ## comma-separated `duPanelLine` field names
  on: bool              ## individually toggleable
  anchor: string        ## topleft | topright | bottomleft | bottomright |
                        ## top | bottom | center
  x: float64            ## offset from that anchor, canvas units
  y: float64            ## Unity Y grows UP, so a top anchor wants negative Y
  w: float64            ## last rendered extent, canvas units -- for hit-test
  h: float64
  lines: int            ## last rendered line count
  dragging: bool
  grabDx: float64       ## cursor offset from the widget's pivot point at grab
  grabDy: float64

var gDuWidgets: seq[DuWidget] = @[]
var gDuEdit = false           ## edit mode: widgets are draggable. DEFAULT OFF.
var gDuEditLogged = false
var gDuLayoutDirty = false
var gDuLayoutSource = "built-in defaults"
var gDuKeyRouteLogged = false

## PER-WIDGET FAULT ISOLATION.
##
## The overlay had exactly one response to a fault: count it, and at eight
## switch the WHOLE panel off. One bad widget therefore took every other widget
## dark with it and the user saw nothing at all -- the "declines silently"
## outcome, reached from a guard that was working perfectly.
##
## The breadcrumb makes a better response possible: a fault raised while a KNOWN
## widget was rendering is charged to that widget, and after
## `cDuWidgetFaultLimit` charges the widget switches itself off. The rest of the
## panel keeps drawing, and the log names the widget instead of a count.
const cDuWidgetFaultLimit = 3
var gDuWidgetFaults: seq[int] = @[]

## The built-in widget set. `id:title:fields` -- and the fields are exactly the
## `duPanelLine` names the single-column panel already understood, so every
## field that worked before still works, just grouped.
const cDuDefaultWidgets = [
  ("fps",     "FPS",      "fps,frametime"),
  ("scene",   "SCENE",    "map,raid"),
  ("pos",     "POSITION", "pos,rot"),
  ("mem",     "MEMORY",   "mem"),
  ("bots",    "BOTS",     "bots,botlist"),
  ("prof",    "PROFILER", "region"),
  ("build",   "BUILD",    "build,frame"),
  ("notes",   "NOTES",    "note1,note2,note3")]

proc duDefaultWidgetSpec(id: string; title, fields: var string): bool =
  for i in 0 ..< cDuDefaultWidgets.len:
    if cDuDefaultWidgets[i][0] == id:
      title = cDuDefaultWidgets[i][1]
      fields = cDuDefaultWidgets[i][2]
      return true
  title = id
  fields = id
  false

## Where each widget starts life the very first time, before anything has been
## dragged. Spread across the corners rather than stacked, so the first F3 shows
## eight distinguishable widgets instead of one illegible pile.
proc duDefaultPlace(id: string; anchor: var string; x, y: var float64) =
  case id
  of "fps":    anchor = "topleft";     x =  16.0; y =  -16.0
  of "scene":  anchor = "topleft";     x =  16.0; y = -104.0
  of "pos":    anchor = "topleft";     x =  16.0; y = -176.0
  of "mem":    anchor = "topright";    x = -16.0; y =  -16.0
  of "bots":   anchor = "bottomleft";  x =  16.0; y =  120.0
  of "prof":   anchor = "topright";    x = -16.0; y =  -88.0
  of "build":  anchor = "bottomleft";  x =  16.0; y =   16.0
  of "notes":  anchor = "bottomright"; x = -16.0; y =   16.0
  else:        anchor = "topleft";     x =  16.0; y =  -16.0

proc duAnchorVec(name: string; ax, ay, px, py: var float64) =
  ## A corner name -> the anchorMin/anchorMax point on the parent (ax, ay) and
  ## the pivot on the label itself (px, py). Setting anchorMin == anchorMax
  ## collapses the label's rect to a POINT on the canvas, so `anchoredPosition`
  ## is then a plain offset from that point; the pivot decides which corner of
  ## the text sits there, which is what stops a top-right panel from hanging off
  ## the right edge of the screen.
  case name
  of "topright":
    ax = 1.0; ay = 1.0; px = 1.0; py = 1.0
  of "bottomleft":
    ax = 0.0; ay = 0.0; px = 0.0; py = 0.0
  of "bottomright":
    ax = 1.0; ay = 0.0; px = 1.0; py = 0.0
  of "top":
    ax = 0.5; ay = 1.0; px = 0.5; py = 1.0
  of "bottom":
    ax = 0.5; ay = 0.0; px = 0.5; py = 0.0
  of "center":
    ax = 0.5; ay = 0.5; px = 0.5; py = 0.5
  else:                       # "topleft" and anything unrecognised
    ax = 0.0; ay = 1.0; px = 0.0; py = 1.0

proc duWidgetPivotPoint(w: DuWidget; cw, ch: float64;
                        pxOut, pyOut: var float64) =
  ## Where the widget's PIVOT sits, in canvas units. This is the point
  ## `anchoredPosition` is measured from, so it is the one place the anchor and
  ## the offset combine.
  var ax = 0.0
  var ay = 1.0
  var px = 0.0
  var py = 1.0
  duAnchorVec(w.anchor, ax, ay, px, py)
  pxOut = ax * cw + w.x
  pyOut = ay * ch + w.y

proc duWidgetRect(w: DuWidget; cw, ch: float64;
                  l, t, r, b: var float64) =
  ## The widget's box in canvas units: left, TOP, right, BOTTOM (Y-up, so
  ## t > b). Uses the extent measured at the last render.
  var ax = 0.0
  var ay = 1.0
  var px = 0.0
  var py = 1.0
  duAnchorVec(w.anchor, ax, ay, px, py)
  var pvx = 0.0
  var pvy = 0.0
  duWidgetPivotPoint(w, cw, ch, pvx, pvy)
  l = pvx - px * w.w
  r = l + w.w
  t = pvy + (1.0 - py) * w.h
  b = t - w.h

proc duWidgetSetTopLeft(w: var DuWidget; cw, ch, l, t: float64) =
  ## The inverse of `duWidgetRect`: given an absolute top-left in canvas units,
  ## write back the anchored offset for the widget's CURRENT anchor.
  var ax = 0.0
  var ay = 1.0
  var px = 0.0
  var py = 1.0
  duAnchorVec(w.anchor, ax, ay, px, py)
  w.x = (l + px * w.w) - ax * cw
  w.y = (t - (1.0 - py) * w.h) - ay * ch

proc duAbs(v: float64): float64 = (if v < 0.0: -v else: v)

proc duNearestAnchor(l, t, cw, ch, wdt, hgt: float64;
                     lockLeft, lockRight, lockTop, lockBottom: bool): string =
  ## Which of the seven anchors this box should now be bound to. A snapped edge
  ## DECIDES its axis; an unsnapped axis falls back to which third of the canvas
  ## the box's centre is in.
  ##
  ## Rebinding rather than keeping the old anchor is the entire reason the saved
  ## layout survives a resolution change: a widget dropped against the right
  ## edge is stored as "right edge, minus 12", not as "x = 2436".
  let cxm = l + wdt * 0.5
  let cym = t - hgt * 0.5
  var hz = 1                       # 0 left, 1 centre, 2 right
  var vt = 1                       # 0 bottom, 1 centre, 2 top
  if lockLeft: hz = 0
  elif lockRight: hz = 2
  elif cxm < cw / 3.0: hz = 0
  elif cxm > cw * 2.0 / 3.0: hz = 2
  if lockBottom: vt = 0
  elif lockTop: vt = 2
  elif cym < ch / 3.0: vt = 0
  elif cym > ch * 2.0 / 3.0: vt = 2
  if hz == 0 and vt == 2: return "topleft"
  if hz == 2 and vt == 2: return "topright"
  if hz == 0 and vt == 0: return "bottomleft"
  if hz == 2 and vt == 0: return "bottomright"
  if hz == 1 and vt == 2: return "top"
  if hz == 1 and vt == 0: return "bottom"
  if hz == 0: return "topleft"     # left edge, vertically central
  if hz == 2: return "topright"
  "center"

proc duSnapWidget(idx: int; cw, ch: float64) =
  ## Snap widget `idx` to the screen edges/corners and to its neighbours, then
  ## rebind its anchor. Called ONCE, on the drop -- never while dragging, so the
  ## widget follows the cursor exactly and only jumps when the user lets go.
  ## A snap that fought the cursor every frame is unusable.
  if idx < 0 or idx >= gDuWidgets.len:
    return
  var l = 0.0
  var t = 0.0
  var r = 0.0
  var b = 0.0
  duWidgetRect(gDuWidgets[idx], cw, ch, l, t, r, b)
  let wdt = gDuWidgets[idx].w
  let hgt = gDuWidgets[idx].h
  if wdt <= 0.0 or hgt <= 0.0:
    return                          # never rendered: nothing to snap

  var lockL = false
  var lockR = false
  var lockT = false
  var lockB = false

  # 1. SCREEN EDGES. Nearest edge wins per axis; both can win, which is what a
  #    corner snap IS.
  if duAbs(l - cDuSnapMargin) <= cDuSnapPx:
    l = cDuSnapMargin; lockL = true
  elif duAbs((cw - cDuSnapMargin) - (l + wdt)) <= cDuSnapPx:
    l = cw - cDuSnapMargin - wdt; lockR = true
  if duAbs((ch - cDuSnapMargin) - t) <= cDuSnapPx:
    t = ch - cDuSnapMargin; lockT = true
  elif duAbs((t - hgt) - cDuSnapMargin) <= cDuSnapPx:
    t = cDuSnapMargin + hgt; lockB = true

  # 2. OTHER WIDGETS -- edge alignment and abutting, but only on an axis the
  #    screen did not already claim, so a corner snap is never dragged back off
  #    the corner by a neighbour. Bounded by the widget count, which is capped.
  for j in 0 ..< gDuWidgets.len:
    if j == idx or not gDuWidgets[j].on:
      continue
    if gDuWidgets[j].w <= 0.0 or gDuWidgets[j].h <= 0.0:
      continue
    var ol = 0.0
    var ot = 0.0
    var orr = 0.0
    var ob = 0.0
    duWidgetRect(gDuWidgets[j], cw, ch, ol, ot, orr, ob)
    if not lockL and not lockR:
      if duAbs(l - ol) <= cDuSnapPx:                 # left edges flush
        l = ol; lockL = true
      elif duAbs(l - (orr + cDuSnapGap)) <= cDuSnapPx:   # sits to its right
        l = orr + cDuSnapGap
      elif duAbs((l + wdt + cDuSnapGap) - ol) <= cDuSnapPx:  # sits to its left
        l = ol - cDuSnapGap - wdt
    if not lockT and not lockB:
      if duAbs(t - ot) <= cDuSnapPx:                 # top edges flush
        t = ot; lockT = true
      elif duAbs(t - (ob - cDuSnapGap)) <= cDuSnapPx:    # stacks below it
        t = ob - cDuSnapGap
      elif duAbs((t - hgt - cDuSnapGap) - ot) <= cDuSnapPx: # stacks above it
        t = ot + cDuSnapGap + hgt

  # 3. Never off-screen, whatever the drag did. A widget dropped past the edge
  #    and then unreachable is a layout the user cannot undo without deleting
  #    the file.
  if l < 0.0: l = 0.0
  if l + wdt > cw: l = cw - wdt
  if t > ch: t = ch
  if t - hgt < 0.0: t = hgt

  gDuWidgets[idx].anchor =
    duNearestAnchor(l, t, cw, ch, wdt, hgt, lockL, lockR, lockT, lockB)
  duWidgetSetTopLeft(gDuWidgets[idx], cw, ch, l, t)


proc duClampOnScreen(idx: int; cw, ch: float64) =
  ## Pull a widget back onto the canvas. Extracted from the draw loop so the
  ## test can drive it: this is the path that runs on the FIRST refresh with no
  ## layout file, against whatever back-buffer size happens to be known, and it
  ## is therefore the path the live fault report pointed at.
  ##
  ## A NON-POSITIVE CANVAS IS A REFUSAL, NOT A CLAMP. Before the region
  ## publishes a size the answer is 0x0, and clamping against a zero-sized
  ## canvas would drag every widget to the origin and (worse) is where a divide
  ## would go wrong. There is no division here at all, and a zero canvas simply
  ## means "leave it where it is until we know".
  if cw <= 0.0 or ch <= 0.0:
    return
  if idx < 0 or idx >= gDuWidgets.len:
    return
  if gDuWidgets[idx].w <= 0.0 or gDuWidgets[idx].h <= 0.0:
    return
  if gDuWidgets[idx].dragging:
    return
  var l = 0.0
  var t = 0.0
  var r = 0.0
  var b = 0.0
  duWidgetRect(gDuWidgets[idx], cw, ch, l, t, r, b)
  var fixed = false
  # Keep at least a sliver of the widget on screen on each axis. Not the whole
  # widget: a widget wider than the canvas would then be unplaceable.
  if l > cw - 24.0:
    l = cw - 24.0; fixed = true
  if l + gDuWidgets[idx].w < 24.0:
    l = 24.0 - gDuWidgets[idx].w; fixed = true
  if t < 24.0:
    t = 24.0; fixed = true
  if t - gDuWidgets[idx].h > ch - 24.0:
    t = ch - 24.0 + gDuWidgets[idx].h; fixed = true
  if fixed:
    duWidgetSetTopLeft(gDuWidgets[idx], cw, ch, l, t)
