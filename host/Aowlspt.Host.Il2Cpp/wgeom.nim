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
  # `region` is the per-participant total; `stages` is that total broken down
  # across the F3 refresh's own breadcrumb stages. The total alone can only ever
  # say "debugui is slow", which is the question, not the answer.
  ("prof",    "PROFILER", "region,stages"),
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
  # TWO DIFFERENT QUESTIONS, WHICH USED TO SHARE ONE ANSWER.
  #
  #   lock*  -- "this EDGE decides the anchor". Only a screen edge or a flush
  #             edge-to-edge alignment sets one, because only those mean the
  #             widget belongs to that side of the screen.
  #   claim* -- "this AXIS is settled; stop scanning". Every successful snap
  #             sets one, including the abutting ones.
  #
  # They were the same flag, and the offline drag test caught what that cost: a
  # widget released 3 units under its neighbour correctly moved to one gap below
  # it (t = 2056 at 4K), then was moved AGAIN, to 2052, by a later widget in the
  # loop whose bottom edge happened to be 4 units away -- because an abutting
  # snap set no flag, nothing stopped the scan, and the LAST widget in the list
  # won however far away it was. The resting place depended on the order the
  # widgets appear in the config file, not on what the user was aiming at.
  #
  # Making abutting set `lock*` instead would fix the scan and break the anchor:
  # a widget stacked under a TOP-anchored neighbour would be bound to "bottom"
  # and would then walk across the screen at a different resolution, which is
  # the one thing anchor+offset exists to prevent.
  var claimX = false
  var claimY = false

  # 1. SCREEN EDGES. Nearest edge wins per axis; both can win, which is what a
  #    corner snap IS.
  if duAbs(l - cDuSnapMargin) <= cDuSnapPx:
    l = cDuSnapMargin; lockL = true; claimX = true
  elif duAbs((cw - cDuSnapMargin) - (l + wdt)) <= cDuSnapPx:
    l = cw - cDuSnapMargin - wdt; lockR = true; claimX = true
  if duAbs((ch - cDuSnapMargin) - t) <= cDuSnapPx:
    t = ch - cDuSnapMargin; lockT = true; claimY = true
  elif duAbs((t - hgt) - cDuSnapMargin) <= cDuSnapPx:
    t = cDuSnapMargin + hgt; lockB = true; claimY = true

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
    if not claimX:
      if duAbs(l - ol) <= cDuSnapPx:                 # left edges flush
        l = ol; lockL = true; claimX = true
      elif duAbs(l - (orr + cDuSnapGap)) <= cDuSnapPx:   # sits to its right
        l = orr + cDuSnapGap; claimX = true
      elif duAbs((l + wdt + cDuSnapGap) - ol) <= cDuSnapPx:  # sits to its left
        l = ol - cDuSnapGap - wdt; claimX = true
    if not claimY:
      if duAbs(t - ot) <= cDuSnapPx:                 # top edges flush
        t = ot; lockT = true; claimY = true
      elif duAbs(t - (ob - cDuSnapGap)) <= cDuSnapPx:    # stacks below it
        t = ob - cDuSnapGap; claimY = true
      elif duAbs((t - hgt - cDuSnapGap) - ot) <= cDuSnapPx: # stacks above it
        t = ot + cDuSnapGap + hgt; claimY = true

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


# ---------------------------------------------------------------------------
# THE DRAG, AS A PURE STATE MACHINE
#
# WHY IT LIVES HERE AND NOT IN `debugui.nim`. It used to be one proc,
# `duDragTick`, that sampled the pointer, decided what to do, did the
# arithmetic, and wrote the layout file -- four jobs, three of them impure, so
# the ONE job that is pure arithmetic could not be exercised without a running
# client. That is exactly the shape CLAUDE.md 9b warns about: the only available
# "check" was to launch the game, press a key and look, and a look that shows
# nothing is indistinguishable from a look at a feature that was never reached.
#
# So the decision half is here, in the file whose hard constraint is that
# NOTHING in it may call the game or Windows. `duDragTick` in `debugui.nim` is
# now a thin adapter: it samples (impure), calls `duDragStep` (pure), and
# persists on a drop (impure). `tests/wgeom_test.nim` drives `duDragStep`
# directly with synthetic pointer states -- press, move, release, focus loss,
# cursor off the client area -- and asserts the FINISHED widget rectangle, not
# the write it just made.
#
# It deliberately reuses the geometry already in this file rather than
# recomputing anything: `duWidgetRect` for the hit box (so the box the user
# grabs is by construction the box that was drawn), `duWidgetPivotPoint` +
# `duAnchorVec` for the offset arithmetic, and `duSnapWidget` for the drop.
# ---------------------------------------------------------------------------

const
  duDragNone    = 0'i32   ## nothing happened this tick
  duDragGrabbed = 1'i32   ## a widget was picked up
  duDragMoved   = 2'i32   ## the held widget followed the cursor
  duDragDropped = 3'i32   ## released and snapped -- THE CALLER MUST PERSIST
  duDragEnded   = 4'i32   ## edit mode left mid-drag; nothing to persist

var gDuDragIdx = -1

proc duDragActive(): bool = gDuDragIdx >= 0

proc duDragRelease() =
  ## Forget any drag in progress without moving or saving anything.
  if gDuDragIdx >= 0 and gDuDragIdx < gDuWidgets.len:
    gDuWidgets[gDuDragIdx].dragging = false
  gDuDragIdx = -1

proc duHitTest(cx, cy, cw, ch: float64): int =
  ## Which widget is under the cursor, or -1.
  ##
  ## TOPMOST-LAST WINS. Widgets are submitted in order and the region rasterises
  ## in submission order, so the LAST one drawn is the one visually on top; the
  ## search therefore runs backwards. Picking the first match would hand the
  ## user the widget hidden underneath the one they can see, which looks like
  ## the drag grabbing nothing at all.
  ##
  ## A widget with no measured extent is not hit-testable and is skipped: `w`
  ## and `h` are written by the draw loop, so a widget that has never been drawn
  ## has a zero box, and a zero box must never match -- `cx >= l and cx <= r`
  ## with l == r is true on the exact pixel, which is a one-pixel invisible
  ## grab handle.
  var i = gDuWidgets.len - 1
  while i >= 0:
    if gDuWidgets[i].on and gDuWidgets[i].w > 0.0 and gDuWidgets[i].h > 0.0:
      var l = 0.0
      var t = 0.0
      var r = 0.0
      var b = 0.0
      duWidgetRect(gDuWidgets[i], cw, ch, l, t, r, b)
      if cx >= l and cx <= r and cy <= t and cy >= b:
        return i
    dec i
  -1

proc duDragGrab(idx: int; cx, cy, cw, ch: float64) =
  ## Record where the cursor sits relative to the widget's PIVOT, so the widget
  ## does not jump to have its pivot under the cursor on the first move. The
  ## offset is stored against the pivot rather than the top-left because the
  ## pivot is what `x`/`y` are measured from, which makes the move arithmetic a
  ## subtraction instead of an anchor-dependent case analysis.
  if idx < 0 or idx >= gDuWidgets.len:
    return
  var pvx = 0.0
  var pvy = 0.0
  duWidgetPivotPoint(gDuWidgets[idx], cw, ch, pvx, pvy)
  gDuWidgets[idx].grabDx = cx - pvx
  gDuWidgets[idx].grabDy = cy - pvy
  gDuWidgets[idx].dragging = true
  gDuDragIdx = idx

proc duDragTo(cx, cy, cw, ch: float64) =
  ## Move the held widget so its pivot keeps the grab offset. NO SNAP HERE --
  ## a snap that engaged every frame fights the cursor and is unusable; the
  ## snap happens once, on the drop.
  if gDuDragIdx < 0 or gDuDragIdx >= gDuWidgets.len:
    return
  var ax = 0.0
  var ay = 1.0
  var px = 0.0
  var py = 1.0
  duAnchorVec(gDuWidgets[gDuDragIdx].anchor, ax, ay, px, py)
  gDuWidgets[gDuDragIdx].x =
    (cx - gDuWidgets[gDuDragIdx].grabDx) - ax * cw
  gDuWidgets[gDuDragIdx].y =
    (cy - gDuWidgets[gDuDragIdx].grabDy) - ay * ch

proc duDragDrop(cw, ch: float64) =
  ## End the drag: snap to edges, corners and neighbours, and rebind the anchor
  ## so the resulting layout is anchor+offset rather than a pixel pair.
  if gDuDragIdx >= 0 and gDuDragIdx < gDuWidgets.len:
    gDuWidgets[gDuDragIdx].dragging = false
    duSnapWidget(gDuDragIdx, cw, ch)
  gDuDragIdx = -1

proc duDragStep(edit, haveCursor: bool; cx, cy, cw, ch: float64;
                pressed, held, released: bool): int32 =
  ## ONE TICK OF THE DRAG, DECIDED PURELY.
  ##
  ## `cw`/`ch` are the canvas the caller has ALREADY established is known and
  ## positive; a caller that has no measured screen must not call this at all,
  ## because snapping against a zero canvas drags every widget to the origin.
  ## That precondition is asserted here as a refusal rather than trusted.
  if not edit:
    if gDuDragIdx >= 0:
      duDragRelease()
      return duDragEnded
    return duDragNone
  if cw <= 0.0 or ch <= 0.0:
    return duDragNone

  # RELEASE IS TESTED FIRST, so a press and a release observed in the same tick
  # (a click faster than the refresh) cannot leave a widget welded to the
  # cursor. The old order let that happen and there was no way to see it
  # without a client.
  if released:
    if gDuDragIdx >= 0:
      duDragDrop(cw, ch)
      return duDragDropped
    gDuDragIdx = -1
    return duDragNone

  if pressed and gDuDragIdx < 0 and haveCursor:
    let idx = duHitTest(cx, cy, cw, ch)
    if idx >= 0:
      duDragGrab(idx, cx, cy, cw, ch)
      return duDragGrabbed
    return duDragNone

  if gDuDragIdx >= 0:
    if held:
      # A cursor that has left the client area HOLDS the widget where it is
      # rather than teleporting it to a clamped edge.
      if haveCursor:
        duDragTo(cx, cy, cw, ch)
        return duDragMoved
      return duDragNone
    # The button went up in a tick we did not observe (a skipped refresh, or a
    # focus change that cleared the button state). Treat it as a drop rather
    # than leaving a widget stuck to the cursor forever -- which is a state the
    # user cannot escape except by restarting the game.
    duDragDrop(cw, ch)
    return duDragDropped
  duDragNone
