## gfxsubtabs_test.nim -- the pure half of the Graphics subtab strip, without
## the client. Drives `graphicssubtabs_pure.nim` directly.
##
## WHY THIS EXISTS. This feature has failed twice, both times in the parts a
## live screen had to catch: an assumed tree shape (fact #104) and a strip whose
## clicks did nothing (fact #117). The geometry and the selection reducer are
## the parts that DON'T need the client, so they are falsified here -- and what
## is asserted is the FINISHED STATE (which panel is active, which button a
## point falls in), never a self-comparison (CLAUDE.md 9b).
##
## Run: aowl run tests/graphicssubtabs/gfxsubtabs_test.nim

import std/syncio

include "../../host/Aowlspt.Host.Il2Cpp/graphicssubtabs_pure.nim"

var failures = 0
var checks = 0

proc check(ok: bool; what: string) =
  inc checks
  if not ok:
    inc failures
    echo "FAIL  ", what

# --- strip geometry: two buttons tile the strip with no gap, no overlap ------
block:
  let w = 400.0'f32
  let h = 40.0'f32
  let g = 0.0'f32
  let a = gfxButtonRect(0'i32, 2'i32, w, h, g)
  let b = gfxButtonRect(1'i32, 2'i32, w, h, g)
  check(a.x == 0.0'f32, "button 0 starts at x=0")
  check(a.w == 200.0'f32, "two buttons split 400 into 200 each")
  check(b.x == 200.0'f32, "button 1 begins where button 0 ends (no gap)")
  check(a.h == h and b.h == h, "buttons take full strip height")
  # they abut but do not overlap: a's right edge == b's left edge
  check(a.x + a.w == b.x, "buttons abut exactly, no overlap, no seam")

# --- with a gap, total width is preserved and the gap sits between -----------
block:
  let a = gfxButtonRect(0'i32, 2'i32, 410.0'f32, 40.0'f32, 10.0'f32)
  let b = gfxButtonRect(1'i32, 2'i32, 410.0'f32, 40.0'f32, 10.0'f32)
  check(a.w == 200.0'f32 and b.w == 200.0'f32, "gap 10 over 410 -> 200 each")
  check(b.x - (a.x + a.w) == 10.0'f32, "the 10px gap sits between the buttons")

# --- an out-of-range or degenerate index yields a zero-area, unclickable rect
block:
  let bad = gfxButtonRect(2'i32, 2'i32, 400.0'f32, 40.0'f32, 0.0'f32)
  check(bad.w == 0.0'f32 and bad.h == 0.0'f32, "index==count -> zero-area rect")
  check(not gfxRectContains(bad, 0.0'f32, 0.0'f32),
        "a zero-area rect contains nothing, not even its origin")
  let none = gfxButtonRect(0'i32, 0'i32, 400.0'f32, 40.0'f32, 0.0'f32)
  check(none.w == 0.0'f32, "count==0 -> zero-area rect")

# --- hit resolution: a point maps to exactly the button it is inside ---------
block:
  let w = 400.0'f32
  let h = 40.0'f32
  check(gfxHit(50.0'f32, 20.0'f32, 2'i32, w, h, 0.0'f32) == 0'i32,
        "a point in the left half hits button 0 (General)")
  check(gfxHit(300.0'f32, 20.0'f32, 2'i32, w, h, 0.0'f32) == 1'i32,
        "a point in the right half hits button 1 (PostFX)")
  check(gfxHit(50.0'f32, 100.0'f32, 2'i32, w, h, 0.0'f32) == -1'i32,
        "a point above the strip hits nothing (y outside)")
  check(gfxHit(-5.0'f32, 20.0'f32, 2'i32, w, h, 0.0'f32) == -1'i32,
        "a point left of the strip hits nothing (x outside)")

# --- the selection reducer: a real click switches, a miss does not -----------
block:
  check(gfxSelectOnClick(GfxSubGeneral, 1'i32) == GfxSubPostFx,
        "clicking PostFX from General selects PostFX")
  check(gfxSelectOnClick(GfxSubPostFx, 0'i32) == GfxSubGeneral,
        "clicking General from PostFX selects General")
  check(gfxSelectOnClick(GfxSubPostFx, 1'i32) == GfxSubPostFx,
        "clicking the active button is idempotent")
  check(gfxSelectOnClick(GfxSubGeneral, -1'i32) == GfxSubGeneral,
        "a click that missed the strip changes nothing")
  check(gfxSelectOnClick(GfxSubPostFx, 9'i32) == GfxSubPostFx,
        "a click on a nonexistent index changes nothing")

# --- the finished-state invariant: EXACTLY ONE panel active, and it is sel ---
# This is the falsifiable property the live readback will assert (fact #117's
# missing check): not "the toggle changed" but "General on XOR PostFX on".
block:
  for sel in [GfxSubGeneral, GfxSubPostFx]:
    let gen = gfxGeneralActive(sel)
    let pfx = gfxPostFxActive(sel)
    check(gen != pfx, "exactly one panel is active for sel=" & $sel)
    check((if sel == GfxSubGeneral: gen else: pfx),
          "the active panel is the selected one for sel=" & $sel)

echo "gfxsubtabs: ", checks - failures, " / ", checks, " checks passed"
if failures > 0:
  echo "gfxsubtabs: ", failures, " FAILURE(S)"
  quit(1)
echo "gfxsubtabs: OK"
