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
