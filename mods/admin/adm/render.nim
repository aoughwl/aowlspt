## Native rendering -- and an honest account of why the pixels are the pending
## part.
##
## The redirection this mod was built under is: draw through the *game's own*
## rendering, never the host's D3D11 overlay. Post-1.0 that means one of two
## Unity surfaces, and both have the same catch:
##
##   * **`GL` immediate mode** (lines for ESP boxes) only rasterises while a
##     camera is rendering -- inside `Camera.OnPostRender` or a command buffer.
##   * **IMGUI `OnGUI`** (a text menu) only runs during the engine's GUI event,
##     and post-1.0 there is no `MonoBehaviour` to receive that event
##     (docs/IL2CPP.md).
##
## Both are *render/GUI-phase* work. The host's main-thread bridge drains its
## queue from a per-frame **Update**-phase method (`EFT.MainApplication::Update`
## and friends -- see the bridge's `bindMainDrain`), so a `GL` or `GUI` call made
## from `everyMain` is on the correct thread at the wrong point in the frame and
## paints nothing.
##
## So this module is written against the interface it needs -- a callback that
## fires **during rendering** on Unity's thread -- and reports, every frame,
## whether that callback exists yet. `renderReady()` is the gate; `setRenderPhase`
## is how the host (or a render-phase detour this mod could install once the
## target method is known on a live build) would hand it the phase. Until then:
##
##   * the ESP geometry is computed every frame and counted, so the data pass is
##     provably working even with nothing on screen;
##   * the menu is laid out and logged, so it is observable in `Player.log`;
##   * `GL` and a colored material are *probed* (not driven), so the diag says
##     whether the drawing surface is even present on this client.
##
## The moment a render-phase drain lands, `drawEspGL`/`drawMenu` below have the
## geometry and the surface and become live with no change to the rest of the mod.

import std/strutils
import aowlspt
import aowlspt/il2cpp
import aowlspt/fast

import state
import world
import cheats

# ---------------------------------------------------------------------------
# The render-phase interface this mod codes against
# ---------------------------------------------------------------------------

var gRenderPhase = false
var gLastDrawn = 0

# GL probe state, declared up here because `renderReady` (below) reads gGlReady.
var gGlReady = false
var gGlTried = false
var gGlWhy = "not attempted"
var bGlBegin: Binding
var bGlEnd: Binding
var bGlVertex3: Binding
var bGlLoadPixel: Binding

proc setRenderPhase*(inPhase: bool) =
  ## The host, or a render-phase detour, calls this true for the duration of a
  ## rendering callback and false otherwise. Nothing does yet -- which is exactly
  ## the pending piece -- so it defaults false and drawing is skipped safely.
  gRenderPhase = inPhase

proc renderReady*(): bool =
  ## True only when we are inside a Unity rendering callback with the GL surface
  ## bound. Both halves are required: right thread AND right phase.
  gRenderPhase and gGlReady

# ---------------------------------------------------------------------------
# Probing the GL drawing surface (readiness only -- not driven)
# ---------------------------------------------------------------------------

proc probeGl() =
  if gGlTried or not worldReady():
    return
  gGlTried = true
  let rt = worldRuntime()
  bGlBegin = bindMethod(rt, "UnityEngine.GL", "Begin", 1)
  bGlEnd = bindMethod(rt, "UnityEngine.GL", "End", 0)
  bGlVertex3 = bindMethod(rt, "UnityEngine.GL", "Vertex3", 3)
  bGlLoadPixel = bindMethod(rt, "UnityEngine.GL", "LoadPixelMatrix", 0)
  gGlReady = bGlBegin.ok and bGlEnd.ok and bGlVertex3.ok
  if gGlReady:
    gGlWhy = "UnityEngine.GL bound; awaiting a render-phase callback to paint"
  else:
    gGlWhy = "UnityEngine.GL not fully bound (Begin=" &
             (if bGlBegin.ok: "ok" else: "no") & " Vertex3=" &
             (if bGlVertex3.ok: "ok" else: "no") & ")"

# ---------------------------------------------------------------------------
# The drawing -- ready to run, gated on the render phase that is pending
# ---------------------------------------------------------------------------

const GL_LINES = 1'i32

proc glLine(x0, y0, x1, y1: float) =
  ## One screen-space line via GL immediate mode. Only meaningful inside a
  ## render-phase callback with a pixel matrix loaded; `renderReady` gates it.
  var a = noArgs()
  addFloat(a, x0); addFloat(a, y0); addFloat(a, 0.0)
  callVoid(bGlVertex3, nullPtr(), a)
  a.reset()
  addFloat(a, x1); addFloat(a, y1); addFloat(a, 0.0)
  callVoid(bGlVertex3, nullPtr(), a)

proc drawEspGL() =
  ## Box every projected entity. Runs only when `renderReady()`.
  var a = noArgs()
  callVoid(bGlLoadPixel, nullPtr(), a)
  a.reset()
  addInt(a, int64(GL_LINES))
  callVoid(bGlBegin, nullPtr(), a)
  let ents = espEntities()
  for e in ents:
    if not e.onScreen:
      continue
    let h = e.bottom - e.top
    if h <= 1.0:
      continue
    let w = h * 0.42
    let l = e.cx - w * 0.5
    let r = e.cx + w * 0.5
    glLine(l, e.top, r, e.top)
    glLine(r, e.top, r, e.bottom)
    glLine(r, e.bottom, l, e.bottom)
    glLine(l, e.bottom, l, e.top)
  a.reset()
  callVoid(bGlEnd, nullPtr(), a)
  gLastDrawn = ents.len

proc drawMenu() =
  ## The F6 menu. Its rows need text, which needs IMGUI/GUI context -- the piece
  ## that is genuinely absent post-1.0. Left as the seam: when a GUI-phase entry
  ## exists, the rows from `menuLines()` are drawn here. Until then the menu is
  ## logged (see `renderFrame`).
  discard

# ---------------------------------------------------------------------------
# The per-frame entry, and the diagnostic
# ---------------------------------------------------------------------------

var gLogTick = 0

proc renderFrame*() =
  ## Called every frame from the mod's Unity-thread tick. Paints when it can,
  ## otherwise keeps the geometry current and makes the menu observable.
  probeGl()
  if renderReady():
    if toggleOn(tgEsp):
      drawEspGL()
    if menuVisible():
      drawMenu()
    return
  # Pending path: nothing to paint into. Log the menu occasionally so it is
  # visible in Player.log, since that is the only surface available right now.
  if menuVisible():
    gLogTick = gLogTick + 1
    if gLogTick mod 180 == 1:
      let lines = menuLines()
      for line in lines:
        info "admin| " & line

proc adminDiag*(): string =
  ## One line joining every sub-system's own account -- what bound, what did
  ## not, and precisely why nothing is on screen yet.
  result = worldDiag() &
           "  |  " & godDiag() &
           "  |  " & staminaDiag() &
           "  |  gl=" & gGlWhy &
           "  |  renderPhase=" & (if gRenderPhase: "yes"
             else: "NO (pending a render-phase Unity-thread hook; " &
                   "Update-phase drain cannot paint)")
