# graphicssubtabs_pure.nim -- the PURE half of the Graphics subtab strip.
#
# Geometry and the selection reducer, with NO il2cpp, NO imports and NO host
# state. This is deliberately the half that can be FALSIFIED offline (CLAUDE.md
# 9b): a strip layout and a which-panel-is-active state machine are exactly the
# parts the two previous attempts got wrong in ways a live screen had to catch.
# `tests/graphicssubtabs/gfxsubtabs_test.nim` includes this file directly.
#
# Coordinate convention matches nuGetRect / aowl_nu_rect_contains: origin
# bottom-left, +y up, all in the strip's own local rect space.

const
  GfxSubGeneral* = 0'i32   ## the existing Graphics content, shown unchanged
  GfxSubPostFx*  = 1'i32   ## the aowlspt graphics-mod postfx controls
  GfxSubCount*   = 2'i32

type GfxRect* = object
  x*, y*, w*, h*: float32

proc gfxButtonRect*(i, count: int32; stripW, stripH, gap: float32): GfxRect =
  ## The i-th of `count` buttons filling a `stripW` x `stripH` strip with `gap`
  ## between neighbours, laid out left-to-right. An out-of-range index or a
  ## non-positive count yields a ZERO-AREA rect, which `gfxRectContains` treats
  ## as containing nothing -- so a degenerate strip can never register a click.
  if count <= 0'i32 or i < 0'i32 or i >= count:
    return GfxRect(x: 0.0'f32, y: 0.0'f32, w: 0.0'f32, h: 0.0'f32)
  let totalGap = gap * float32(count - 1'i32)
  let bw = (stripW - totalGap) / float32(count)
  GfxRect(x: float32(i) * (bw + gap), y: 0.0'f32, w: bw, h: stripH)

proc gfxRectContains*(r: GfxRect; px, py: float32): bool =
  ## A zero-area rect contains nothing (the invoke2 zero-area failure, applied
  ## here so a failed layout cannot be "clicked" by accident).
  if r.w <= 0.0'f32 or r.h <= 0.0'f32: return false
  px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h

proc gfxHit*(px, py: float32; count: int32; stripW, stripH, gap: float32): int32 =
  ## Which button local-point (px,py) falls in, or -1. Buttons do not overlap
  ## for gap >= 0, so the first container is THE answer; capped by count.
  result = -1'i32
  var i = 0'i32
  while i < count:
    if gfxRectContains(gfxButtonRect(i, count, stripW, stripH, gap), px, py):
      return i
    inc i

proc gfxSelectOnClick*(cur, hit: int32): int32 =
  ## The selection reducer. A click that missed the strip (hit < 0), or one on
  ## a nonexistent index, changes NOTHING; a click on a real button selects it.
  ## Idempotent on the already-active button.
  if hit < 0'i32 or hit >= GfxSubCount: return cur
  hit

# The finished-state predicates. Asserting on THESE (not on "the click handler
# ran", not on a toggle's m_IsOn -- fact #117) is what the live readback checks:
# exactly one content panel active, and it is the selected one.
proc gfxGeneralActive*(sel: int32): bool = sel == GfxSubGeneral
proc gfxPostFxActive*(sel: int32): bool = sel == GfxSubPostFx
