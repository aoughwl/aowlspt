## wgeom_test.nim -- the widget placement path, WITHOUT the client.
##
## WHY THIS EXISTS. The overlay's first live run faulted on its first refresh,
## every time, and self-disabled after eight faults with a log line that said
## only "fault #1 caught by the VEH guard". The user saw nothing. There was no
## way to reproduce any of it except by launching the game and pressing F3.
##
## `wgeom.nim` is the pure half of that path -- the built-in placement, the
## anchor maths, the snap and the on-screen clamp -- with no managed call and no
## Windows call in it. This drives that half directly, at the two back-buffer
## sizes that actually occur:
##
##   0 x 0        what the region reports BEFORE anything publishes a size.
##                Every widget must survive it unchanged; nothing may divide by
##                it, and nothing may "clamp" against it.
##   3840 x 2160  the size the live run reported.
##
## WHAT IT ASSERTS IS THE FINISHED STATE, never its own writes: after placement
## every widget must be a finite, on-screen, non-degenerate rectangle. A check
## that compared the result to the value just written could not fail and would
## be worth nothing.
##
## Run: aowl run tests/wgeom_test.nim

import std/syncio

# The unit under test, verbatim -- not a copy of it.
include "../host/Aowlspt.Host.Il2Cpp/wgeom.nim"

var failures = 0
var checks = 0
var failed = false

proc check(ok: bool; what: string) =
  inc checks
  if not ok:
    inc failures
    echo "FAIL  ", what

proc finite(v: float64): bool =
  ## NaN != NaN is the portable NaN test, and a magnitude bound catches both
  ## infinities without needing `Inf` from std/math. Written out rather than
  ## imported so this test has no dependency that could itself be the thing
  ## that breaks.
  if v != v:
    return false
  v > -1.0e30 and v < 1.0e30

proc fabs(v: float64): float64 = (if v < 0.0: -v else: v)

proc seedBuiltIns() =
  ## EXACTLY the path taken when there is no layout file -- which is the state
  ## the live fault occurred in ("no layout file yet" in the host log).
  gDuWidgets = @[]
  for i in 0 ..< cDuDefaultWidgets.len:
    let id = cDuDefaultWidgets[i][0]
    var w = DuWidget(id: id, title: cDuDefaultWidgets[i][1],
                     fields: cDuDefaultWidgets[i][2], on: true,
                     anchor: "topleft", x: 0.0, y: 0.0,
                     w: 0.0, h: 0.0, lines: 0,
                     dragging: false, grabDx: 0.0, grabDy: 0.0)
    duDefaultPlace(id, w.anchor, w.x, w.y)
    # A plausible rendered extent, as the draw loop would have measured it.
    w.w = 380.0
    w.h = 88.0
    gDuWidgets.add w

proc exercise(cw, ch: float64; label: string) =
  seedBuiltIns()
  for i in 0 ..< gDuWidgets.len:
    duClampOnScreen(i, cw, ch)
  for i in 0 ..< gDuWidgets.len:
    let w = gDuWidgets[i]
    let tag = label & " widget '" & w.id & "'"
    check(finite(w.x) and finite(w.y), tag & ": offset is finite")
    var l = 0.0
    var t = 0.0
    var r = 0.0
    var b = 0.0
    duWidgetRect(w, cw, ch, l, t, r, b)
    check(finite(l) and finite(t) and finite(r) and finite(b),
          tag & ": rect is finite")
    check(r > l and t > b, tag & ": rect is non-degenerate")
    if cw > 0.0 and ch > 0.0:
      # On a KNOWN canvas every widget must be reachable by the mouse.
      check(l < cw and r > 0.0, tag & ": horizontally on screen")
      check(b < ch and t > 0.0, tag & ": vertically on screen")

proc exerciseSnap(cw, ch: float64) =
  ## Drop every widget at a deliberately absurd place and snap it. The snap must
  ## always land it back on screen with a recognised anchor -- that is the
  ## property, not any particular coordinate.
  seedBuiltIns()
  # Deliberately absurd drop points: far off each edge, the origin, and the
  # middle. Two parallel float seqs rather than a seq of tuples, which nimony
  # will not infer an element type for.
  var sx: seq[float64] = @[]
  var sy: seq[float64] = @[]
  sx.add(-9000.0); sy.add(-9000.0)
  sx.add(99000.0); sy.add(99000.0)
  sx.add(0.0);     sy.add(0.0)
  sx.add(cw * 0.5); sy.add(ch * 0.5)
  for k in 0 ..< sx.len:
    for i in 0 ..< gDuWidgets.len:
      gDuWidgets[i].x = sx[k]
      gDuWidgets[i].y = sy[k]
      duSnapWidget(i, cw, ch)
      let a = gDuWidgets[i].anchor
      check(a == "topleft" or a == "topright" or a == "bottomleft" or
            a == "bottomright" or a == "top" or a == "bottom" or a == "center",
            "snap: '" & gDuWidgets[i].id & "' has a recognised anchor, got '" &
            a & "'")
      check(finite(gDuWidgets[i].x) and finite(gDuWidgets[i].y),
            "snap: '" & gDuWidgets[i].id & "' offset is finite")
      var l = 0.0
      var t = 0.0
      var r = 0.0
      var b = 0.0
      duWidgetRect(gDuWidgets[i], cw, ch, l, t, r, b)
      check(l >= -1.0 and r <= cw + 1.0 and b >= -1.0 and t <= ch + 1.0,
            "snap: '" & gDuWidgets[i].id & "' is fully on screen after a drop")

proc exerciseRoundTrip(cw, ch: float64) =
  ## `duWidgetSetTopLeft` must be the exact inverse of `duWidgetRect` for every
  ## anchor. A drag reads one and writes the other every frame; if they disagree
  ## the widget creeps across the screen while held.
  seedBuiltIns()
  var anchors: seq[string] = @[]
  anchors.add "topleft"
  anchors.add "topright"
  anchors.add "bottomleft"
  anchors.add "bottomright"
  anchors.add "top"
  anchors.add "bottom"
  anchors.add "center"
  for a in 0 ..< anchors.len:
    var w = gDuWidgets[0]
    w.anchor = anchors[a]
    w.x = 37.0
    w.y = -61.0
    var l = 0.0
    var t = 0.0
    var r = 0.0
    var b = 0.0
    duWidgetRect(w, cw, ch, l, t, r, b)
    let x0 = w.x
    let y0 = w.y
    duWidgetSetTopLeft(w, cw, ch, l, t)
    check(fabs(w.x - x0) < 0.001 and fabs(w.y - y0) < 0.001,
          "round trip on anchor '" & anchors[a] & "': got (" & $w.x & "," &
          $w.y & ") want (" & $x0 & "," & $y0 & ")")

proc widgetCentre(i: int; cw, ch: float64; cx, cy: var float64) =
  var l = 0.0
  var t = 0.0
  var r = 0.0
  var b = 0.0
  duWidgetRect(gDuWidgets[i], cw, ch, l, t, r, b)
  cx = (l + r) * 0.5
  cy = (t + b) * 0.5

proc exerciseHitTest(cw, ch: float64) =
  ## THE GRAB. Two negatives and one positive, because a hit test that always
  ## answers "yes" is exactly the check-that-cannot-fail this repo keeps
  ## producing: the interesting assertions are the misses.
  seedBuiltIns()
  duDragRelease()
  for i in 0 ..< gDuWidgets.len:
    var cx = 0.0
    var cy = 0.0
    widgetCentre(i, cw, ch, cx, cy)
    let hit = duHitTest(cx, cy, cw, ch)
    # Not `== i`: widgets may overlap, and the CONTRACT is topmost-last, not
    # identity. What must hold is that the reported hit really does contain the
    # point -- asserted against the finished rectangle, not against the index.
    check(hit >= 0, "hit: the centre of widget '" & gDuWidgets[i].id &
          "' hits something")
    if hit >= 0:
      var l = 0.0
      var t = 0.0
      var r = 0.0
      var b = 0.0
      duWidgetRect(gDuWidgets[hit], cw, ch, l, t, r, b)
      check(cx >= l and cx <= r and cy <= t and cy >= b,
            "hit: the widget returned for '" & gDuWidgets[i].id &
            "' actually contains the point")
      check(hit >= i, "hit: topmost-last -- the answer for '" &
            gDuWidgets[i].id & "' is not a widget drawn EARLIER than it")

  # A point well away from every widget must MISS. The built-ins live near the
  # edges, so the middle of the canvas is empty -- assert that it is empty
  # rather than assume it.
  check(duHitTest(cw * 0.47, ch * 0.5, cw, ch) < 0,
        "hit: the middle of the canvas grabs nothing")

  # A widget that has never been drawn has a ZERO extent and must never be
  # grabbable -- otherwise it is an invisible one-pixel handle.
  gDuWidgets[0].w = 0.0
  gDuWidgets[0].h = 0.0
  var px = 0.0
  var py = 0.0
  duWidgetPivotPoint(gDuWidgets[0], cw, ch, px, py)
  check(duHitTest(px, py, cw, ch) != 0,
        "hit: a widget with no measured extent is not grabbable")

  # A widget that is switched OFF is not on screen and must not be grabbable.
  seedBuiltIns()
  gDuWidgets[4].on = false
  var ox = 0.0
  var oy = 0.0
  widgetCentre(4, cw, ch, ox, oy)
  check(duHitTest(ox, oy, cw, ch) != 4,
        "hit: a widget that is switched off is not grabbable")

proc exerciseDrag(cw, ch: float64) =
  ## THE WHOLE GESTURE, tick by tick, exactly as `duDragTick` feeds it.
  seedBuiltIns()
  duDragRelease()

  # Edit mode OFF: a press over a widget must do nothing at all. This is the
  # property that keeps the overlay from changing what the mouse does in a raid.
  var cx = 0.0
  var cy = 0.0
  widgetCentre(0, cw, ch, cx, cy)
  let x0 = gDuWidgets[0].x
  let y0 = gDuWidgets[0].y
  check(duDragStep(false, true, cx, cy, cw, ch, true, true, false) == duDragNone,
        "drag: a press with edit mode OFF is ignored")
  check(gDuWidgets[0].x == x0 and gDuWidgets[0].y == y0,
        "drag: a press with edit mode OFF moves nothing")

  # GRAB at a deliberately OFF-CENTRE point, so a widget that jumped to put its
  # pivot under the cursor would be caught. Grabbing at the centre could not
  # detect that.
  var l0 = 0.0
  var t0 = 0.0
  var r0 = 0.0
  var b0 = 0.0
  duWidgetRect(gDuWidgets[0], cw, ch, l0, t0, r0, b0)
  let gx = l0 + 11.0
  let gy = t0 - 7.0
  check(duDragStep(true, true, gx, gy, cw, ch, true, true, false) == duDragGrabbed,
        "drag: a press inside a widget grabs it")
  check(duDragActive(), "drag: a grab leaves the machine holding something")
  check(gDuWidgets[0].x == x0 and gDuWidgets[0].y == y0,
        "drag: the grab frame itself does not move the widget")

  # MOVE. The cursor-to-box offset must be preserved EXACTLY, which is the
  # property a user sees as "the widget does not jump". Asserted on the
  # finished rectangle, not on the offset just written.
  let dx = 640.0
  let dy = -350.0
  check(duDragStep(true, true, gx + dx, gy + dy, cw, ch, false, true, false) ==
        duDragMoved, "drag: a held move reports a move")
  var l1 = 0.0
  var t1 = 0.0
  var r1 = 0.0
  var b1 = 0.0
  duWidgetRect(gDuWidgets[0], cw, ch, l1, t1, r1, b1)
  check(fabs((l1 - l0) - dx) < 0.001 and fabs((t1 - t0) - dy) < 0.001,
        "drag: the box followed the cursor exactly, got d=(" & $(l1 - l0) &
        "," & $(t1 - t0) & ")")
  check(fabs((r1 - l1) - (r0 - l0)) < 0.001 and
        fabs((t1 - b1) - (t0 - b0)) < 0.001,
        "drag: a move does not resize the widget")

  # CURSOR LEAVES THE CLIENT AREA mid-drag: the widget HOLDS, it does not
  # teleport to a clamped edge.
  check(duDragStep(true, false, 0.0, 0.0, cw, ch, false, true, false) ==
        duDragNone, "drag: a move with no cursor sample is a no-op")
  var l2 = 0.0
  var t2 = 0.0
  var r2 = 0.0
  var b2 = 0.0
  duWidgetRect(gDuWidgets[0], cw, ch, l2, t2, r2, b2)
  check(fabs(l2 - l1) < 0.001 and fabs(t2 - t1) < 0.001,
        "drag: losing the cursor holds the widget where it was")

  # DROP.
  check(duDragStep(true, true, gx + dx, gy + dy, cw, ch, false, false, true) ==
        duDragDropped, "drag: a release drops and asks the caller to persist")
  check(not duDragActive(), "drag: the drop clears the held widget")
  check(not gDuWidgets[0].dragging, "drag: the drop clears the dragging flag")

  # A RELEASE WITH NOTHING HELD must not report a drop -- otherwise every click
  # anywhere in edit mode rewrites the layout file.
  check(duDragStep(true, true, cx, cy, cw, ch, false, false, true) == duDragNone,
        "drag: a release with nothing held does not ask to persist")

  # PRESS AND RELEASE IN THE SAME TICK (a click faster than the refresh) must
  # not leave a widget welded to the cursor.
  seedBuiltIns()
  duDragRelease()
  discard duDragStep(true, true, cx, cy, cw, ch, true, false, true)
  check(not duDragActive(),
        "drag: a press and release in one tick leaves nothing held")

  # THE BUTTON WENT UP IN A TICK WE DID NOT SEE. Held falls to 0 with no release
  # edge -- the machine must drop, not hold forever.
  seedBuiltIns()
  duDragRelease()
  discard duDragStep(true, true, gx, gy, cw, ch, true, true, false)
  check(duDragActive(), "drag: (setup) the widget is held")
  check(duDragStep(true, true, gx, gy, cw, ch, false, false, false) ==
        duDragDropped, "drag: a lost button edge is treated as a drop")
  check(not duDragActive(), "drag: a lost button edge does not weld the widget")

  # LEAVING EDIT MODE mid-drag ends it and asks for NO save.
  seedBuiltIns()
  duDragRelease()
  discard duDragStep(true, true, gx, gy, cw, ch, true, true, false)
  check(duDragStep(false, true, gx, gy, cw, ch, false, true, false) ==
        duDragEnded, "drag: leaving edit mode mid-drag ends the drag")
  check(not duDragActive() and not gDuWidgets[0].dragging,
        "drag: leaving edit mode mid-drag releases the widget")

  # AN UNKNOWN CANVAS is a refusal, never a snap to the origin.
  seedBuiltIns()
  duDragRelease()
  let zx = gDuWidgets[0].x
  let zy = gDuWidgets[0].y
  check(duDragStep(true, true, 10.0, 10.0, 0.0, 0.0, true, true, false) ==
        duDragNone, "drag: a 0x0 canvas refuses to step the machine")
  check(gDuWidgets[0].x == zx and gDuWidgets[0].y == zy,
        "drag: a 0x0 canvas moves nothing")

proc dropAt(idx: int; cw, ch, l, t: float64) =
  ## Put widget `idx`'s top-left at (l, t) by driving the REAL gesture -- grab
  ## at its own top-left, move by the delta, release -- rather than by writing
  ## `x`/`y` directly. A test that sets the field it then checks proves nothing;
  ## this one goes through the same three ticks the mouse produces.
  duDragRelease()
  var cl = 0.0
  var ct = 0.0
  var cr = 0.0
  var cb = 0.0
  duWidgetRect(gDuWidgets[idx], cw, ch, cl, ct, cr, cb)
  discard duDragStep(true, true, cl, ct, cw, ch, true, true, false)
  discard duDragStep(true, true, l, t, cw, ch, false, true, false)
  discard duDragStep(true, true, l, t, cw, ch, false, false, true)

proc exerciseDropSnap(cw, ch: float64) =
  ## THE DROP RESOLVES TO AN EDGE, A CORNER OR A NEIGHBOUR -- asserted on where
  ## the widget ENDS UP, never on the coordinate handed to the drag.
  seedBuiltIns()
  duDragRelease()
  let wdt = gDuWidgets[0].w

  # LEFT EDGE, released a few units inside the snap radius.
  dropAt(0, cw, ch, cDuSnapMargin + 3.0, ch - 600.0)
  var l = 0.0
  var t = 0.0
  var r = 0.0
  var b = 0.0
  duWidgetRect(gDuWidgets[0], cw, ch, l, t, r, b)
  check(fabs(l - cDuSnapMargin) < 0.001,
        "snapdrop: a drop near the left edge rests ON the margin, got l=" & $l)

  # TOP-RIGHT CORNER -- both axes must snap, and the anchor must REBIND, which
  # is what makes the saved layout survive a resolution change.
  seedBuiltIns()
  dropAt(0, cw, ch, cw - cDuSnapMargin - wdt - 5.0, ch - cDuSnapMargin + 4.0)
  duWidgetRect(gDuWidgets[0], cw, ch, l, t, r, b)
  check(fabs((cw - cDuSnapMargin) - r) < 0.001 and
        fabs((ch - cDuSnapMargin) - t) < 0.001,
        "snapdrop: a drop near the top-right corner rests on BOTH margins, " &
        "got r=" & $r & " t=" & $t)
  check(gDuWidgets[0].anchor == "topright",
        "snapdrop: a top-right drop rebinds the anchor to topright, got '" &
        gDuWidgets[0].anchor & "'")

  # RESOLUTION CHANGE -- the whole point of persisting anchor+offset. The SAME
  # widget re-measured against a different canvas must still be on the same
  # corner at the same margin, not at the same pixel.
  var l3 = 0.0
  var t3 = 0.0
  var r3 = 0.0
  var b3 = 0.0
  duWidgetRect(gDuWidgets[0], 1280.0, 720.0, l3, t3, r3, b3)
  check(fabs((1280.0 - cDuSnapMargin) - r3) < 0.001 and
        fabs((720.0 - cDuSnapMargin) - t3) < 0.001,
        "snapdrop: the same layout re-measured at 1280x720 is still on the " &
        "top-right margin, got r=" & $r3 & " t=" & $t3)

  # A NEIGHBOUR. Park widget 1 on the top-right corner, then release widget 0
  # just below it and require it to come to rest against widget 1 -- an
  # alignment that is NOT any screen edge, so only the neighbour rule can
  # produce it.
  seedBuiltIns()
  dropAt(1, cw, ch, cw - cDuSnapMargin - gDuWidgets[1].w, ch - cDuSnapMargin)
  var nl = 0.0
  var nt = 0.0
  var nr = 0.0
  var nb = 0.0
  duWidgetRect(gDuWidgets[1], cw, ch, nl, nt, nr, nb)
  dropAt(0, cw, ch, nl, nb - cDuSnapGap + 3.0)
  duWidgetRect(gDuWidgets[0], cw, ch, l, t, r, b)
  check(fabs(l - nl) < 0.001,
        "snapdrop: the neighbour's LEFT edge is matched, got l=" & $l &
        " want " & $nl)
  check(fabs(t - (nb - cDuSnapGap)) < 0.001,
        "snapdrop: the drop rests one gap BELOW the neighbour, got t=" & $t &
        " want " & $(nb - cDuSnapGap))

  # And after every one of those drops nothing is off screen or NaN.
  for i in 0 ..< gDuWidgets.len:
    duWidgetRect(gDuWidgets[i], cw, ch, l, t, r, b)
    check(finite(l) and finite(t) and finite(r) and finite(b),
          "snapdrop: '" & gDuWidgets[i].id & "' rect is finite after drops")
    check(l >= -1.0 and r <= cw + 1.0 and b >= -1.0 and t <= ch + 1.0,
          "snapdrop: '" & gDuWidgets[i].id & "' is on screen after drops")

# The whole suite as ONE exported entry point, returning the failure count.
#
# `aowl run` builds a file under `tests/` as a mod DLL, not an executable, so a
# `when isMainModule` block in here is compiled and then never executed -- a
# test that cannot run is not a test. Exporting the suite means the DLL that
# the existing build already produces can be loaded and called directly
# (`tools/run_wgeom_test.py`), with no new build target and no raw nimony
# invocation.
proc wgeomTestRun(): int32 {.exportc: "aowl_wgeom_test_run", cdecl.} =
  # THE UNPUBLISHED BACK BUFFER. `aowl_region_screen_known()` is 0 here and the
  # canvas is 0x0; the first refresh after F3 can genuinely be in this state.
  exercise(0.0, 0.0, "0x0")
  # A 0x0 canvas must leave the built-in placement exactly as authored: a clamp
  # against an unknown canvas is a bug, not a safety measure.
  seedBuiltIns()
  let beforeX = gDuWidgets[3].x
  let beforeY = gDuWidgets[3].y
  duClampOnScreen(3, 0.0, 0.0)
  check(gDuWidgets[3].x == beforeX and gDuWidgets[3].y == beforeY,
        "a 0x0 canvas leaves the built-in placement untouched")

  # The size the live run actually reported.
  exercise(3840.0, 2160.0, "3840x2160")
  exerciseSnap(3840.0, 2160.0)
  exerciseRoundTrip(3840.0, 2160.0)
  # THE DRAG. Pure by construction -- `duDragStep` takes a pointer state as
  # plain numbers and returns what it decided -- so the gesture that could
  # previously only be tested by launching the game and looking is driven here,
  # at both a 4K and a 1080p canvas.
  exerciseHitTest(3840.0, 2160.0)
  exerciseDrag(3840.0, 2160.0)
  exerciseDropSnap(3840.0, 2160.0)
  exerciseHitTest(1920.0, 1080.0)
  exerciseDrag(1920.0, 1080.0)
  exerciseDropSnap(1920.0, 1080.0)

  # And a canvas smaller than a widget, which the clamp must not turn into NaN.
  exercise(200.0, 120.0, "200x120")

  echo ""
  if failures == 0:
    echo "PASS  ", checks, " checks, 0 failures"
  else:
    echo "FAIL  ", checks, " checks, ", failures, " failure(s)"
    # A non-zero exit, so `aowl run` and any CI wrapper see the failure rather
    # than a green run with a sad word in it.
    failed = true

  int32(failures)

{.emit: """
/* `int` rather than `int32_t`: this emit lands near the top of the generated C,
 * before <stdint.h> is pulled in, so the fixed-width name is not declared yet.
 * `int` is 32-bit on every target this tree builds for and needs no header. */
extern int aowl_wgeom_test_run(void);
__declspec(dllexport) int aowl_wgeom_test_run_x(void) {
    return aowl_wgeom_test_run();
}
""".}

when isMainModule:
  discard wgeomTestRun()
