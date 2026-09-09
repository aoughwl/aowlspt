# inspoverlay.nim -- the F2 LIVE-INSPECTOR OVERLAY.
#
# A read-only, D3D11-rasterised panel that shows what the live inspector is doing
# in real time: its bound anchors, and a scrolling ring of the commands it has
# run and the answer lines they produced. It is how a human WATCHES a find, a
# press, or the auto-raid loop happen, instead of tailing aowlspt-inspect-out.txt.
#
# WHY THIS IS SAFE BY CONSTRUCTION
# --------------------------------
# It is a DRAW PARTICIPANT in the shared region -- the exact path the F3 debug
# overlay, the F12 settings panel and the F6 admin HUD already use, the one
# human-confirmed to render (fact #196). It does NOT clone a TextMeshProUGUI and
# it does NOT build native uGUI (both unproven-visible). Concretely, that hands
# this file five of the eight host rules for free:
#
#   * ONE SEH guard -- the region dispatches every participant inside the
#     overlay body's single `aowl_p_p_seh`. This file arms no guard of its own;
#     doing so would DISARM that one (it is not re-entrant).
#   * SELF-DISABLE after N faults -- the region counts per-participant faults and
#     drops a participant that keeps faulting (`aowl_wg_rg_faults`/`_disabled`).
#   * NO NEW DETOUR -- registration, not a hook, so the double-detour trap that
#     kills the first feature's trampoline cannot apply.
#   * CAPPED ITERATION -- every loop below is bounded by a config value that is
#     itself clamped, or by a compile-time constant.
#   * NO PER-FRAME MANAGED ALLOCATION -- the anchor and activity lines are read
#     out of fixed C buffers (`aowl_io_*`) straight into `cWgDrText`; the only
#     composed string, the status header, is recomposed ONLY when its inputs
#     change and cached between times.
#
# The remaining three -- flag-gated default OFF, validate before read, never
# blind-write -- this file satisfies directly: it is gated on `inspectorOverlay`
# (default off) plus an F2 toggle; it only READS the inspector's own published
# snapshot; and it writes nothing into any game object, only draw commands into
# the overlay's own command buffer.
#
# WHERE THE DATA COMES FROM. `inspect.nim` (included just before this file) taps
# every answer line and every command into the ring, and republishes its anchors
# each batch -- all on Unity's thread, all gated on `gIoCapture`, which this file
# sets true only when the panel arms. This file just reads that snapshot in
# `Present`, under the ring's own dedicated lock.

# ---- the native ring's read side (writers are in inspect.nim) --------------
proc cIoCount(): int32 {.importc: "aowl_io_count_get", nodecl.}
proc cIoSeq(): int64 {.importc: "aowl_io_seq_get", nodecl.}
proc cIoGet(j: int32; outp: ptr char): int32 {.importc: "aowl_io_get", nodecl.}
proc cIoAnchorCount(): int32 {.importc: "aowl_io_anchor_count", nodecl.}
proc cIoAnchorGet(j: int32; outp: ptr char): int32 {.
  importc: "aowl_io_anchor_get", nodecl.}

# ---------------------------------------------------------------------------
# Config -- a FLAT JSON file, `aowlspt-inspoverlay.json`, beside the host DLL.
# Flat and read with the same shallow scanner the debug overlay uses (`duCfg*`,
# defined in debugui.nim, in scope here because that file is included first).
# Every value is defaulted, so a missing or malformed file weakens nothing; the
# feature stays OFF until `inspectorOverlay` is set in aowlspt-host.json.
# ---------------------------------------------------------------------------
type IoCfg = object
  toggleVk: int          ## virtual-key code for show/hide; 0x71 = VK_F2
  panelX: float64        ## top-left X in back-buffer px
  panelY: float64        ## top-left Y in back-buffer px
  widthCols: int         ## panel width in character cells (<= 63, the region cap)
  maxLines: int          ## activity lines shown (the newest N)
  fontScale: int         ## 0 = auto by screen height; 1/2/3 = fixed
  showHeader: bool       ## the status line (batch, dispatches, on/off, faults)
  showAnchors: bool      ## the bound-anchors section
  showActivity: bool     ## the command/answer ring
  startVisible: bool     ## show the moment it arms, before any F2 press
  bgR, bgG, bgB, bgA: float64   ## panel background colour, 0..1
  fgR, fgG, fgB: float64        ## answer-line text colour, 0..1
  cmdR, cmdG, cmdB: float64     ## command-line text colour, 0..1
  hdrR, hdrG, hdrB: float64     ## header + section-title colour, 0..1

var gIoCfg = IoCfg(
  toggleVk: 0x71, panelX: 24.0, panelY: 24.0, widthCols: 60, maxLines: 22,
  fontScale: 0, showHeader: true, showAnchors: true, showActivity: true,
  startVisible: false,
  bgR: 0.02, bgG: 0.02, bgB: 0.05, bgA: 0.82,
  fgR: 0.82, fgG: 0.90, fgB: 0.82,
  cmdR: 0.55, cmdG: 0.85, cmdB: 1.0,
  hdrR: 1.0, hdrG: 0.85, hdrB: 0.35)

var gIoCfgSource = "(built-in defaults)"

proc ioCfgTemplate(): string =
  ## Written once if the file is absent -- the cheapest documentation there is.
  "{\n" &
  "  \"toggleKey\":    113,\n" &        # 113 = 0x71 = VK_F2
  "  \"panelX\":       24,\n" &
  "  \"panelY\":       24,\n" &
  "  \"widthCols\":    60,\n" &
  "  \"maxLines\":     22,\n" &
  "  \"fontScale\":    0,\n" &          # 0 = auto by screen height
  "  \"showHeader\":   true,\n" &
  "  \"showAnchors\":  true,\n" &
  "  \"showActivity\": true,\n" &
  "  \"startVisible\": false,\n" &
  "  \"bgColor\":      \"0.02,0.02,0.05\",\n" &
  "  \"bgAlpha\":      0.82,\n" &
  "  \"textColor\":    \"0.82,0.90,0.82\",\n" &
  "  \"cmdColor\":     \"0.55,0.85,1.0\",\n" &
  "  \"headerColor\":  \"1.0,0.85,0.35\"\n" &
  "}\n"

proc ioLoadConfig() =
  ## Read `aowlspt-inspoverlay.json`, or keep the built-in defaults. Called at
  ## arm AND on every toggle-ON, so the file can be edited and the panel
  ## re-toggled without a restart.
  let path = joinPath(gDir, "aowlspt-inspoverlay.json")
  var text = ""
  if not readTextFile(path, text):
    discard writeTextFile(path, ioCfgTemplate())
    gIoCfgSource = path & " (created with defaults)"
    return
  gIoCfgSource = path
  gIoCfg.toggleVk   = duCfgInt(text, "toggleKey", gIoCfg.toggleVk, 0, 255)
  gIoCfg.panelX     = duCfgNum(text, "panelX", gIoCfg.panelX)
  gIoCfg.panelY     = duCfgNum(text, "panelY", gIoCfg.panelY)
  gIoCfg.widthCols  = duCfgInt(text, "widthCols", gIoCfg.widthCols, 20, 63)
  gIoCfg.maxLines   = duCfgInt(text, "maxLines", gIoCfg.maxLines, 1, 40)
  gIoCfg.fontScale  = duCfgInt(text, "fontScale", gIoCfg.fontScale, 0, 3)
  gIoCfg.showHeader   = duCfgBool(text, "showHeader", gIoCfg.showHeader)
  gIoCfg.showAnchors  = duCfgBool(text, "showAnchors", gIoCfg.showAnchors)
  gIoCfg.showActivity = duCfgBool(text, "showActivity", gIoCfg.showActivity)
  gIoCfg.startVisible = duCfgBool(text, "startVisible", gIoCfg.startVisible)
  gIoCfg.bgA        = duCfgNum(text, "bgAlpha", gIoCfg.bgA)
  # Locals, then assign -- `duParseRgb` takes `var` params and leaves them
  # untouched on a malformed triple, so a partial colour is never applied.
  var r = 0.0
  var g = 0.0
  var b = 0.0
  r = gIoCfg.bgR; g = gIoCfg.bgG; b = gIoCfg.bgB
  duParseRgb(duCfgStr(text, "bgColor", ""), r, g, b)
  gIoCfg.bgR = r; gIoCfg.bgG = g; gIoCfg.bgB = b
  r = gIoCfg.fgR; g = gIoCfg.fgG; b = gIoCfg.fgB
  duParseRgb(duCfgStr(text, "textColor", ""), r, g, b)
  gIoCfg.fgR = r; gIoCfg.fgG = g; gIoCfg.fgB = b
  r = gIoCfg.cmdR; g = gIoCfg.cmdG; b = gIoCfg.cmdB
  duParseRgb(duCfgStr(text, "cmdColor", ""), r, g, b)
  gIoCfg.cmdR = r; gIoCfg.cmdG = g; gIoCfg.cmdB = b
  r = gIoCfg.hdrR; g = gIoCfg.hdrG; b = gIoCfg.hdrB
  duParseRgb(duCfgStr(text, "headerColor", ""), r, g, b)
  gIoCfg.hdrR = r; gIoCfg.hdrG = g; gIoCfg.hdrB = b

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var gIoOn = false            ## master arm (the `inspectorOverlay` host flag)
var gIoVisible = false       ## F2 show/hide
var gIoRegionHandle = -1     ## the shared-region participant handle, or -1
var gIoDrawBuf: array[64, char]   ## fixed scratch for one line, NO allocation
var gIoKeyRouteLogged = false

# The status header is composed only when its inputs change, then cached.
var gIoHeader = ""
var gIoHdrSeq = -1'i64
var gIoHdrBatch = -1
var gIoHdrVis = false

proc ioColour(r, g, b: float64): uint32 =
  duRgba(int(r * 255.0), int(g * 255.0), int(b * 255.0), 255)

proc ioScale(): int32 =
  if gIoCfg.fontScale > 0:
    int32(gIoCfg.fontScale)
  else:
    duTextScale(float64(cWgScrH()))

proc ioDrawStored(x, y: float32; col: uint32; scale: int32) =
  ## Draw whatever `cIoGet`/`cIoAnchorGet` last copied into `gIoDrawBuf`. The
  ## buffer is NUL-terminated by the C side and never exceeds 63 usable chars.
  if gIoDrawBuf[0] == chr(0):
    return
  discard cWgDrText(x, y, cast[cstring](addr gIoDrawBuf[0]), col, scale)

proc ioComposeHeader(seqNow: int64) =
  ## Recompose the status line ONLY when something it reports has changed. This
  ## is the single composed string on the draw path, and this is what keeps it
  ## off the per-frame allocation budget.
  if gInspBatch == gIoHdrBatch and seqNow == gIoHdrSeq and gIoVisible == gIoHdrVis:
    return
  gIoHdrBatch = gInspBatch
  gIoHdrSeq = seqNow
  gIoHdrVis = gIoVisible
  var st = "inspector "
  if gInspOff: st.add "OFF(faulted)"
  elif gInspOn: st.add "ON"
  else: st.add "idle"
  gIoHeader = "aowl live inspector  batch " & $gInspBatch &
              "  fires " & $gInspFires & "  " & st
  # 63 is the renderer's hard cap; trim here so the header never looks cut.
  if gIoHeader.len > 62:
    var cut = ""
    for i in 0 ..< 61:
      cut.add gIoHeader[i]
    gIoHeader = cut & ">"

proc ioDrawPanel() =
  let scale = ioScale()
  let cellW = 8.0'f32 * float32(scale)
  let cellH = 16.0'f32 * float32(scale)
  let lineH = cellH + 2.0'f32
  let x0 = float32(gIoCfg.panelX)
  var y = float32(gIoCfg.panelY)
  let pad = 6.0'f32

  # ---- count the rows we will draw, so the background is sized exactly -------
  var rows = 0
  if gIoCfg.showHeader: rows += 1
  var nAnchor = 0
  if gIoCfg.showAnchors:
    nAnchor = int(cIoAnchorCount())
    if nAnchor > 24: nAnchor = 24
    rows += 1 + nAnchor            # a title + the anchor lines
  var nAct = 0
  if gIoCfg.showActivity:
    nAct = int(cIoCount())
    if nAct > gIoCfg.maxLines: nAct = gIoCfg.maxLines
    rows += 1 + nAct              # a title + the activity lines
  if rows < 1: rows = 1

  let panelW = float32(gIoCfg.widthCols) * cellW + pad * 2.0'f32
  let panelH = float32(rows) * lineH + pad * 2.0'f32

  # ---- background + border (draw commands only; nothing game-side written) ---
  discard cWgDrFill(x0 - pad, y - pad, panelW, panelH,
                    duRgba(int(gIoCfg.bgR * 255.0), int(gIoCfg.bgG * 255.0),
                           int(gIoCfg.bgB * 255.0), int(gIoCfg.bgA * 255.0)))
  discard cWgDrBox(x0 - pad, y - pad, panelW, panelH, 1.0'f32,
                   ioColour(gIoCfg.hdrR, gIoCfg.hdrG, gIoCfg.hdrB))

  let colFg  = ioColour(gIoCfg.fgR, gIoCfg.fgG, gIoCfg.fgB)
  let colCmd = ioColour(gIoCfg.cmdR, gIoCfg.cmdG, gIoCfg.cmdB)
  let colHdr = ioColour(gIoCfg.hdrR, gIoCfg.hdrG, gIoCfg.hdrB)

  # ---- header ----------------------------------------------------------------
  if gIoCfg.showHeader:
    ioComposeHeader(cIoSeq())
    if gIoHeader.len > 0:
      # Copy the cached header into the fixed draw buffer -- nimony refuses
      # cstring() on a non-literal, and this keeps the draw path allocation-free.
      var n = gIoHeader.len
      if n > 63: n = 63
      for i in 0 ..< n:
        gIoDrawBuf[i] = gIoHeader[i]
      gIoDrawBuf[n] = chr(0)
      ioDrawStored(x0, y, colHdr, scale)
    y += lineH

  # ---- anchors ---------------------------------------------------------------
  if gIoCfg.showAnchors:
    discard cWgDrText(x0, y, cstring("-- anchors --"), colHdr, scale)
    y += lineH
    var i = 0
    while i < nAnchor:
      discard cIoAnchorGet(int32(i), addr gIoDrawBuf[0])
      ioDrawStored(x0, y, colFg, scale)
      y += lineH
      inc i

  # ---- activity (newest N, oldest-first so it reads top-to-bottom) -----------
  if gIoCfg.showActivity:
    discard cWgDrText(x0, y, cstring("-- activity --"), colHdr, scale)
    y += lineH
    let total = int(cIoCount())
    var first = total - nAct
    if first < 0: first = 0
    var j = first
    while j < total:
      let kind = cIoGet(int32(j), addr gIoDrawBuf[0])
      ioDrawStored(x0, y, (if kind == 0'i32: colCmd else: colFg), scale)
      y += lineH
      inc j

proc ioRegionDraw(user: pointer; frame: int64) {.
    exportc: "aowl_io_region_draw", cdecl.} =
  ## The DRAW participant, dispatched every `Present` inside the overlay body's
  ## single SEH guard. Costs nothing when the feature is off, and only a
  ## foreground + key-edge read when armed-but-hidden.
  discard user
  discard frame
  if not gIoOn:
    return
  # The F2 toggle, sampled BEFORE the visibility gate (otherwise a hidden panel
  # could never be shown). Foreground-gated so an F2 typed into another window
  # cannot toggle it. `cDuKeyEdge` reads GetAsyncKeyState -- async key state, not
  # a window message, so the WM_KEYDOWN/WM_SYSKEYDOWN routing that hid F10 from
  # the old wndproc cannot apply.
  if cDuForeground() != 0'i32 and gIoCfg.toggleVk > 0 and
     cDuKeyEdge(int32(gIoCfg.toggleVk)) != 0'i32:
    if not gIoKeyRouteLogged:
      gIoKeyRouteLogged = true
      okLog "inspoverlay: toggle key vk=0x" & hexOf(uint64(gIoCfg.toggleVk)) &
            " edge OBSERVED via GetAsyncKeyState"
    gIoVisible = not gIoVisible
    if gIoVisible:
      ioLoadConfig()     # re-read config on every show, so edits apply live
    okLog "inspoverlay: panel " & (if gIoVisible: "ON" else: "OFF")
  if not gIoVisible:
    return
  ioDrawPanel()

proc ioArm(verbose: bool): bool =
  ## Register the panel as a DRAW participant and start the inspector feeding the
  ## ring. Says WHY it failed using the region's own refusal text, never a bare
  ## number -- an F2 that silently draws nothing is the failure this path avoids.
  if gIoRegionHandle >= 0:
    return true
  ioLoadConfig()
  let h = cWgRgRegister(cstring("inspoverlay"), ioRegionDraw,
                        cWgRgMaskDraw(), 60'i32, 700'i32)
  if h < 0:
    warn "inspoverlay: could NOT register with the shared region -- " &
         $cWgRgRefusalTextC(h) & ". The F2 panel will not draw; this is " &
         "reported here rather than as an empty screen. (The shared region " &
         "must be armed -- set sharedRegion in aowlspt-host.json.)"
    return false
  gIoRegionHandle = h
  gIoCapture = true                 # inspect.nim starts feeding the ring now
  gIoVisible = gIoCfg.startVisible
  okLog "inspoverlay: F2 live-inspector panel registered as DRAW participant " &
        $h & " (config " & gIoCfgSource & "). It is rasterised by the D3D11 " &
        "overlay in Present -- the same path as F3/F12/F6. Press vk=0x" &
        hexOf(uint64(gIoCfg.toggleVk)) & " in game to toggle it. If nothing " &
        "appears, aowl_wg_rg_armed() reports whether the shared region is live."
  if verbose and not gInspOn:
    warn "inspoverlay: armed, but liveInspector is OFF, so the ring will stay " &
         "empty -- the panel shows inspector activity and there is none. Set " &
         "liveInspector to see it do anything."
  true
