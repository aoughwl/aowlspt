## ===========================================================================
## colorwidget -- THE NATIVE COLOUR CONTROL ON THE IN-GAME SETTINGS SCREEN
##
## WHAT THIS REPLACES. A `color` setting used to reach the in-game settings
## screen as `swkStub` with `implemented = false`: drawn, labelled, and
## suffixed "(not done yet)". That was honest and it was not a control. The web
## settings UI (`mods/uihub`) already had a real picker, so the half the player
## was actually asking about was the only half missing.
##
## WHY IT IS BUILT AND NOT CLONED. Every other native row here is a CLONE of a
## live game widget, because cloning inherits styling, layout and behaviour for
## free. There is no colour control anywhere on a stock settings tab to clone --
## `SETTINGS-CONTROLS-RE.md` sec.4 lists what is there, and it is toggles,
## sliders and dropdowns. So this is BUILT from `nuikit` primitives, which is
## the path proven live on 2026-08-30 (IMAGEPROOF VERDICT = PASS): a
## from-scratch `UnityEngine.UI.Image` renders, and `nuPanel`/`nuLabel` encode
## the one ordering that makes it render.
##
## WHAT IT LOOKS LIKE. Per row, laid out to the right of the row's own label,
## all of it parented to the row's clone GameObject so it inherits the row's
## position and is destroyed with it:
##
##   [swatch]  [R====----]  [G=======-]  [B=-------]   R 68  G 119  B 17
##
## The swatch is one panel in the current colour. Each channel is TWO panels --
## a dark track and a bright fill drawn over it, the fill's width being the
## channel value. There is no sprite, no mask and no material: an `Image` with
## a null sprite and `m_Type == Simple` emits one quad over its rect in
## `m_Color`, which is exactly a bar.
##
## HOW IT IS DRIVEN. POLLED, from the `TarkovApplication::Update` drain, on the
## Unity main thread. NOT by an `onValueChanged` delegate and NOT through the
## EventSystem: a managed `UnityAction` needs a valid `invoke_impl` and a valid
## `MethodInfo*` for a method that exists in no assembly, and nothing about
## that is demonstrated on this build. `nativeui.nim`'s INPUT section has said
## polling is the answer since it was written; it simply had no pointer source,
## and `nuHitTest` had zero call sites in the entire host. `nuMousePos` /
## `nuMouseDown` / `nuScreenRectOf` are that missing half.
##
## THE FOUR NEW MANAGED TARGETS, all appended to `aowl_nu_targets` at indices
## 32..35, all resolved offline, all sharedness=UNIQUE (owners=1), all with
## real bodies -- none is the `C2 00 00` universal empty-body stub at 0x628110:
##
##   UnityEngine.Input::GetMouseButton                  RVA 0x531EBD0
##   UnityEngine.Input::get_mousePosition_Injected      RVA 0x531F740
##   UnityEngine.Transform::get_position_Injected       RVA 0x52BA1E0
##   UnityEngine.Transform::get_lossyScale_Injected     RVA 0x52BAA50
##
## `UnityEngine.Input` here is the STATIC legacy API in
## UnityEngine.InputLegacyModule. It is NOT `UnityEngine.UIElements.Input`,
## which is what a by-member-name search finds FIRST, is an INSTANCE class, and
## whose `get_mousePosition` at 0xCF96D0 is SHARED by four methods.
##
## ONE FIELD OFFSET, measured with `tools/fldoff.py` (whose mandatory
## `System.String._stringLength@0x10` self-check passed on the same run):
##
##   UnityEngine.UI.Graphic.m_Canvas   @ 0x60
##
## It is read for ONE purpose: the screen mapping below is only valid for a
## `ScreenSpaceOverlay` canvas, so the widget asks the swatch which Canvas
## Unity's own ancestor walk gave it and refuses to arm interaction unless
## `Canvas::get_renderMode` reads 0. A mapping applied to the wrong render mode
## does not fail -- it produces a finite, entirely fictional channel value,
## which is the class of bug this repo keeps paying for.
##
## THE EIGHT RULES.
##   1. Prologue byte-verify -- every call goes through `nuFn`, which verifies
##      against the STARTUP SNAPSHOT (`abi/aowlspt_prologue.h`), never live
##      memory. Plus `nuTargetsBindOk`, the POSITIONAL check this change also
##      adds, because appending rows to an index-addressed table is precisely
##      the 2026-08-24 defect.
##   2. Every pointer hop validated -- `nuOk`/`nuAlive`, and `nkResolve` for
##      every handle, which additionally catches RELEASED and STALE-GENERATION.
##   3. ONE `aowl_p_p_seh`, opened by `aowl_cw_tick_guarded`, around the whole
##      tick. This file opens NO guard of its own: the guard is not re-entrant
##      and a nested inner guard disarms the outer one.
##   4. Capped iteration -- `cCwMax` widgets, 3 channels, no walk of any game
##      collection at all.
##   5. Flag-gated, default OFF -- `settingsColorWidget`.
##   6. Self-disable after N faults -- `AOWL_CW_MAX_FAULTS`, counted in C.
##   7. No per-frame managed allocation -- the widget is built ONCE. The tick
##      does `_Injected` getters, `Graphic::set_color` and layout setters, all
##      on objects we allocated. The readout label's text is the one thing that
##      could allocate, and it is rewritten ONLY when the 8-bit value changes,
##      through `nuSetText` -> `nuStr`, which interns.
##   8. Never blind-write -- an unparseable colour is refused, not defaulted;
##      an unmappable rect is refused, not guessed.
##
## WHAT THIS FILE MAY NOT CLAIM. That the control is usable. Nobody can claim
## that without a human dragging it. What `cwVerdict` establishes is the
## FINISHED STATE, by READBACK: how many colour rows have a live swatch whose
## `m_Color` reads back as the colour the setting holds, and how many still
## render as an unbound stub. It reports one of exactly three outcomes and
## INCONCLUSIVE is a real one.
## ===========================================================================

{.emit: """
extern void* aowl_cw_tick_body(void* a);
static void* aowl_cw_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_cw_tick_body, a);
}

/* SELF-DISABLE. Six is enough to distinguish "one bad frame during a scene
 * change" from "this path faults every frame forever", and small enough that
 * the second case costs the player six frames rather than the session. */
#define AOWL_CW_MAX_FAULTS 6
static int32_t g_aowl_cw_faults = 0;
static int32_t aowl_cw_fault_count(void) { return g_aowl_cw_faults; }
static void    aowl_cw_note_fault(void)  { if (g_aowl_cw_faults < 1000) g_aowl_cw_faults++; }
static int32_t aowl_cw_disabled(void)    { return g_aowl_cw_faults >= AOWL_CW_MAX_FAULTS ? 1 : 0; }
static int32_t aowl_cw_max_faults(void)  { return AOWL_CW_MAX_FAULTS; }
""".}

proc cCwTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_cw_tick_guarded", nodecl.}
proc cCwNoteFault() {.importc: "aowl_cw_note_fault", nodecl.}
proc cCwFaultCount(): int32 {.importc: "aowl_cw_fault_count", nodecl.}
proc cCwDisabled(): int32 {.importc: "aowl_cw_disabled", nodecl.}
proc cCwMaxFaults(): int32 {.importc: "aowl_cw_max_faults", nodecl.}

# ---------------------------------------------------------------------------
# GEOMETRY. All offsets are in the ROW CLONE's local space, top-left anchored
# with y negative going down -- `nuPanel`'s documented convention, and the one
# the IMAGEPROOF run used. These are laid out to the RIGHT of where a stock
# settings row puts its caption, so the row's own label is not covered.
# ---------------------------------------------------------------------------
const
  cCwMax          = 6           ## widgets alive at once. A CAP, not a target.
  cCwChannels     = 3           ## R, G, B. Alpha is carried and NOT edited --
                                ## see `cwAlphaNote` below.
  cCwSwatchX      = 470.0'f32
  cCwSwatchW      =  44.0'f32
  cCwTrackX       = 524.0'f32
  cCwTrackW       =  84.0'f32
  cCwTrackGap     =  90.0'f32
  cCwReadoutX     = 800.0'f32
  cCwReadoutW     = 200.0'f32
  cCwRowY         =  -4.0'f32
  cCwRowH         =  22.0'f32
  cCwFontSize     =  16.0'f32
  ## The track's unfilled part. Dark but not black, so an empty channel is
  ## still visibly a control rather than a hole in the panel.
  cCwTrackR       = 0.13'f32
  cCwTrackG       = 0.13'f32
  cCwTrackB       = 0.15'f32
  cCwTrackA       = 0.85'f32
  ## `Canvas.RenderMode.ScreenSpaceOverlay`. Named because `0` in a comparison
  ## against a render mode is the value we are trying to PROVE, not a default.
  cCwOverlayMode  = 0'i32
  ## `UnityEngine.UI.Graphic.m_Canvas`, measured (tools/fldoff.py, self-check
  ## System.String._stringLength@0x10 passed on the same invocation).
  cCwOffGraphicCanvas = 0x60'i32

## Alpha is stored, round-tripped and rendered, and is NOT editable by drag.
## A fourth bar is easy; an alpha channel the player can drag to zero on a
## colour whose only job is to be seen is a control whose most reachable state
## is "this feature stopped working". If a mod needs editable alpha it should
## say so and get a fourth bar behind its own decision, not by default.
const cwAlphaNote = "alpha is carried and rendered, not editable by drag"

type
  CwWidget = object
    used: bool
    key: string                 ## the setting key, for the log line only
    guid: string                ## owning mod, for the log line only
    r, g, b, a: float32         ## what we last WROTE. Never read back FROM.
    swatch: NuElem
    track0, track1, track2: NuElem
    fill0, fill1, fill2: NuElem
    readout: NuElem
    lastText: string            ## so the readout is rewritten only on change
    ## -1 = not dragging, 0..2 = the channel the pointer grabbed. A drag is
    ## captured on the press and held until release even if the pointer leaves
    ## the bar, which is what every slider in every UI does and what stops a
    ## fast drag from snapping back.
    drag: int32
    ## Interaction is armed only once the swatch's Canvas has been READ and
    ## found to be ScreenSpaceOverlay. Until then the widget renders and does
    ## not respond -- a visible control that ignores the mouse is bad, and a
    ## control that responds to a mapping known to be wrong is worse.
    armed: bool
    armTried: bool

var gCwOn = false               ## `settingsColorWidget`, default OFF
var gCwWidgets: seq[CwWidget] = @[]
var gCwBuilt = 0
var gCwRefused = 0
var gCwEdits = 0
var gCwArmRefusalLogged = false
var gCwTicks = 0'i64
var gCwLastVerdict = ""

proc cwFillOf(w: CwWidget; ch: int): NuElem =
  case ch
  of 0: w.fill0
  of 1: w.fill1
  else: w.fill2

proc cwTrackOf(w: CwWidget; ch: int): NuElem =
  case ch
  of 0: w.track0
  of 1: w.track1
  else: w.track2

proc cwChanValue(w: CwWidget; ch: int): float32 =
  case ch
  of 0: w.r
  of 1: w.g
  else: w.b

proc cwSetChanValue(w: var CwWidget; ch: int; v: float32) =
  case ch
  of 0: w.r = v
  of 1: w.g = v
  else: w.b = v

proc cwChanName(ch: int): string =
  case ch
  of 0: "R"
  of 1: "G"
  else: "B"

proc cwByte(v: float32): int =
  var x = v
  if not (x > 0.0'f32): x = 0.0'f32       # NaN-safe: !(x > 0) catches NaN
  if x > 1.0'f32: x = 1.0'f32
  int(x * 255.0'f32 + 0.5'f32)

proc cwReadoutText(w: CwWidget): string =
  ## What the player reads. 0..255 per channel, because that is the form the
  ## stored `#rrggbb` is in and a 0..1 float on screen would not match anything
  ## the web picker or the config file shows.
  "R " & $cwByte(w.r) & "   G " & $cwByte(w.g) & "   B " & $cwByte(w.b)

proc cwTrackXOf(ch: int): float32 =
  cCwTrackX + float32(ch) * cCwTrackGap

# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------
proc cwApplyVisual(w: var CwWidget) =
  ## Push `w`'s colour onto the live elements. Called at build and after every
  ## change; it is the ONLY place that writes the widget's appearance, so there
  ## is one path to be wrong rather than three.
  discard nuSetColor(w.swatch, w.r, w.g, w.b, w.a)
  var ch = 0
  while ch < cCwChannels:                 # capped by construction
    let v = cwChanValue(w, ch)
    var frac = v
    if not (frac > 0.0'f32): frac = 0.0'f32
    if frac > 1.0'f32: frac = 1.0'f32
    # A fill of literally zero width is a zero-area rect, which `nuLayout`
    # refuses (correctly -- it cannot render). Floor it at one pixel so a
    # channel at 0 still shows a handle rather than the element disappearing
    # and the refusal being logged every frame.
    let fw = 1.0'f32 + frac * (cCwTrackW - 1.0'f32)
    discard nuSetRect(cwFillOf(w, ch), cwTrackXOf(ch), cCwRowY, fw, cCwRowH)
    # The fill is tinted with its OWN channel so the bars are self-labelling:
    # the red bar is red. Kept at full brightness rather than the channel value
    # so a channel at 0.1 is still legible.
    discard nuSetColor(cwFillOf(w, ch),
                       (if ch == 0: 1.0'f32 else: 0.25'f32),
                       (if ch == 1: 1.0'f32 else: 0.25'f32),
                       (if ch == 2: 1.0'f32 else: 0.25'f32), 1.0'f32)
    ch = ch + 1
  let txt = cwReadoutText(w)
  if txt != w.lastText:
    # RULE 7. `nuSetText` interns, so this allocates at most once per distinct
    # string for the life of the process -- but only if it is not called with
    # the same string every frame, which is what this compare is for.
    discard nuSetText(w.readout, txt)
    w.lastText = txt

proc cwTeardown(w: var CwWidget) =
  ## Destroy every element this widget owns and SPEND every handle. Called on a
  ## failed build (so a half-built widget never survives) and from
  ## `cwDestroySlot`.
  discard nuDestroy(w.readout)
  discard nuDestroy(w.fill0)
  discard nuDestroy(w.fill1)
  discard nuDestroy(w.fill2)
  discard nuDestroy(w.track0)
  discard nuDestroy(w.track1)
  discard nuDestroy(w.track2)
  discard nuDestroy(w.swatch)
  w.used = false
  w.armed = false

proc cwDestroySlot(slot: int32) =
  if slot < 0'i32 or int(slot) >= gCwWidgets.len: return
  if not gCwWidgets[int(slot)].used: return
  cwTeardown(gCwWidgets[int(slot)])
  okLog "colorwidget: slot " & $slot & " torn down"

proc cwBuildForRow(rowClone, parentGo: Il2CppPtr; key, modGuid: string;
                   r, g, b, a: float32): int32 =
  ## Build the widget for one colour row. Returns the slot index, or -1 with a
  ## NAMED refusal already logged. Never partially succeeds: any failure tears
  ## down whatever was built.
  ##
  ## `rowClone` is the row's own cloned control, used as the PARENT so the
  ## widget inherits the row's position in the settings list and dies with it.
  ## `parentGo` is the row container, used only for the donor-TMP search.
  result = -1'i32
  if not gCwOn:
    return -1'i32
  if cCwDisabled() != 0'i32:
    warn "colorwidget: DECLINED to build '" & key & "' -- this path has " &
         "self-disabled after " & $cCwFaultCount() & " fault(s) (cap " &
         $cCwMaxFaults() & ")"
    return -1'i32
  if not nuTargetsBindOk():
    warn "colorwidget: DECLINED to build '" & key & "' -- the aowl_nu_targets " &
         "positional binding self-check FAILED (the nativeui line above names " &
         "the index). Every call would be to the wrong method."
    return -1'i32
  if not nuOk(rowClone, 0x20'i32) or not nuAlive(rowClone):
    warn "colorwidget: DECLINED to build '" & key & "' -- the row clone is " &
         "null, unreadable or a destroyed Unity object"
    return -1'i32

  # A donor TMP is MANDATORY for `nuLabel`: a from-scratch TextMeshProUGUI with
  # a null `m_fontAsset` faults inside its own Awake. Take it from the row's
  # own clone first (it is a settings row, so it has a caption), then the row
  # container. No donor is a refusal, not a best-effort.
  var donorTmp = swControlTmp(rowClone)
  if donorTmp == nil and parentGo != nil:
    donorTmp = swControlTmp(parentGo)
  if donorTmp == nil or not nuOk(donorTmp, 0x20'i32) or not nuAlive(donorTmp):
    warn "colorwidget: DECLINED to build '" & key & "' -- no live donor " &
         "TextMeshProUGUI on the row or its container to copy a font asset " &
         "from. Building one from scratch without a font faults in Awake, so " &
         "there is nothing safe to build."
    inc gCwRefused
    return -1'i32

  # Find a free slot. Capped: the table is `cCwMax` long.
  while gCwWidgets.len < cCwMax:
    gCwWidgets.add CwWidget(used: false, drag: -1'i32)
  var slot = -1
  var i = 0
  while i < gCwWidgets.len:
    if not gCwWidgets[i].used:
      slot = i
      break
    i = i + 1
  if slot < 0:
    warn "colorwidget: DECLINED to build '" & key & "' -- all " & $cCwMax &
         " widget slots are in use. This is a CAP, deliberately: a schema " &
         "with fifty colour keys must not instantiate fifty widgets into a " &
         "live screen."
    inc gCwRefused
    return -1'i32

  var w = CwWidget(used: true, key: key, guid: modGuid,
                   r: r, g: g, b: b, a: a, lastText: "", drag: -1'i32,
                   armed: false, armTried: false)
  # Alpha of exactly 0 would build an invisible swatch and read back as a
  # perfectly successful build of a control nobody can see -- this project's
  # signature false positive. A colour setting with no alpha specified parses
  # as a = 1.0; a colour that really is fully transparent is shown at a floor
  # so the control still exists on screen, and the stored alpha is untouched.
  var swatchA = w.a
  if swatchA < 0.25'f32: swatchA = 0.25'f32

  w.swatch = nuPanel(rowClone, cCwSwatchX, cCwRowY, cCwSwatchW, cCwRowH,
                     w.r, w.g, w.b, swatchA, "aowl-cw-swatch")
  if w.swatch == nuNone:
    warn "colorwidget: DECLINED to build '" & key & "' -- the swatch panel " &
         "did not build (nuikit logged the reason above)"
    inc gCwRefused
    return -1'i32

  # Tracks first, fills second: nuikit parents each new element as the LAST
  # sibling, and uGUI draws siblings in order, so the fill is drawn over its
  # track precisely because it is created after it. Reordering these two loops
  # would hide every fill behind its track while every call still succeeded.
  var ch = 0
  var okAll = true
  while ch < cCwChannels and okAll:
    let t = nuPanel(rowClone, cwTrackXOf(ch), cCwRowY, cCwTrackW, cCwRowH,
                    cCwTrackR, cCwTrackG, cCwTrackB, cCwTrackA,
                    "aowl-cw-track-" & cwChanName(ch))
    if t == nuNone: okAll = false
    else:
      if ch == 0: w.track0 = t
      elif ch == 1: w.track1 = t
      else: w.track2 = t
    ch = ch + 1
  ch = 0
  while ch < cCwChannels and okAll:
    let f = nuPanel(rowClone, cwTrackXOf(ch), cCwRowY, 1.0'f32, cCwRowH,
                    1.0'f32, 1.0'f32, 1.0'f32, 1.0'f32,
                    "aowl-cw-fill-" & cwChanName(ch))
    if f == nuNone: okAll = false
    else:
      if ch == 0: w.fill0 = f
      elif ch == 1: w.fill1 = f
      else: w.fill2 = f
    ch = ch + 1
  if okAll:
    w.readout = nuLabel(rowClone, donorTmp, cCwReadoutX, cCwRowY,
                        cCwReadoutW, cCwRowH, cwReadoutText(w), cCwFontSize,
                        1.0'f32, 1.0'f32, 1.0'f32, 1.0'f32, "aowl-cw-readout")
    if w.readout == nuNone: okAll = false
    else: w.lastText = cwReadoutText(w)
  if not okAll:
    warn "colorwidget: build of '" & key & "' FAILED partway (nuikit logged " &
         "which element refused). Tearing down what was built rather than " &
         "leaving a half-drawn control on screen."
    cwTeardown(w)
    inc gCwRefused
    return -1'i32

  cwApplyVisual(w)
  gCwWidgets[slot] = w
  inc gCwBuilt
  okLog "colorwidget: built slot " & $slot & " for '" & key &
        (if modGuid.len > 0: "' (mod " & modGuid & ")" else: "' (host page)") &
        " at " & $cwByte(w.r) & "/" & $cwByte(w.g) & "/" & $cwByte(w.b) &
        " -- 8 elements (swatch, 3 tracks, 3 fills, readout). Interaction is " &
        "NOT armed yet: it arms on the first tick, and only if the swatch's " &
        "Canvas reads back ScreenSpaceOverlay. " & cwAlphaNote & "."
  result = int32(slot)

# ---------------------------------------------------------------------------
# READ-BACK -- the finished state, from the live tree
# ---------------------------------------------------------------------------
proc cwRowColor(slot: int32; r, g, b, a: var float32): bool =
  ## The colour the LIVE swatch is actually rendering, read out of the scene
  ## through `nuElemColor` -> `Graphic.m_Color`.
  ##
  ## This deliberately does NOT return `gCwWidgets[slot].r/g/b`, the record of
  ## what we last wrote. `swReadBackPage` compares this against the row's
  ## stored value to decide whether the player changed anything, and comparing
  ## our own write against our own write is a check that cannot fail -- the
  ## exact defect that reported "0 did not take" for 16 visibly-wrong rows.
  r = 0.0'f32; g = 0.0'f32; b = 0.0'f32; a = 0.0'f32
  if slot < 0'i32 or int(slot) >= gCwWidgets.len: return false
  if not gCwWidgets[int(slot)].used: return false
  let (ok, lr, lg, lb, la) = nuElemColor(gCwWidgets[int(slot)].swatch)
  if not ok: return false
  r = lr; g = lg; b = lb; a = la
  true

# ---------------------------------------------------------------------------
# INTERACTION -- one guarded tick, ridden on the Update drain
# ---------------------------------------------------------------------------
proc cwArm(w: var CwWidget): bool =
  ## Establish that the screen mapping this widget is about to use is VALID,
  ## once, and record the answer.
  ##
  ## `nuScreenRectOf` maps world space to screen space on the assumption of a
  ## ScreenSpaceOverlay canvas, where Unity makes those the same space. Under
  ## ScreenSpaceCamera or WorldSpace that assumption is silently false: the
  ## mapping still returns finite numbers, the hit test still succeeds
  ## sometimes, and the channel value it produces is fiction. So ask.
  ##
  ## The Canvas comes from `Graphic.m_Canvas` @ 0x60 on the swatch -- the field
  ## UNITY filled by its own ancestor walk in OnEnable, which is a better
  ## answer than any walk of ours, because it is the canvas that will actually
  ## draw this element.
  w.armTried = true
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(w.swatch, "cwArm", go, rt, comp, kind): return false
  if not nuOk(comp, cCwOffGraphicCanvas + 0x8'i32): return false
  let canvas = cNuGetRef(comp, cCwOffGraphicCanvas)
  if canvas == nil or not nuOk(canvas, 0x20'i32) or not nuAlive(canvas):
    if not gCwArmRefusalLogged:
      gCwArmRefusalLogged = true
      warn "colorwidget: NOT arming interaction -- the swatch's " &
           "Graphic.m_Canvas (@0x60) is null or not a live object. Unity " &
           "fills it in OnEnable by ancestor walk, so this means the element " &
           "has no Canvas above it and is not being drawn at all. The widget " &
           "stays visible-but-inert rather than mapping the pointer through " &
           "a canvas that does not exist."
    return false
  let fn = nuFn(NuTCanvasGetMode)
  if fn == nil: return false
  # -1 is not a legal RenderMode, so "could not ask" can never be mistaken for
  # ScreenSpaceOverlay(0) -- which is the exact value being tested for.
  let mode = cNuCallIP(fn, canvas, -1'i32)
  if mode != cCwOverlayMode:
    if not gCwArmRefusalLogged:
      gCwArmRefusalLogged = true
      warn "colorwidget: NOT arming interaction -- the swatch's Canvas " &
           "reports renderMode=" & $mode & ", and the pointer mapping is " &
           "only valid for ScreenSpaceOverlay(" & $cCwOverlayMode & "). " &
           "Under any other mode the mapping returns finite numbers that are " &
           "fiction. The widget renders and does not respond; that is a " &
           "REFUSAL, not a failure."
    return false
  okLog "colorwidget: interaction ARMED for '" & w.key & "' -- swatch Canvas " &
        "renderMode reads " & $mode & " (ScreenSpaceOverlay), so world space " &
        "IS screen space and the pointer mapping is valid"
  w.armed = true
  true

proc cwHitChannel(w: CwWidget; mx, my: float32; frac: var float32): int32 =
  ## Which channel bar is the pointer over, and how far along it (0..1)?
  ## -1 for none. Every rejection is a rejection of the WHOLE hit, never a
  ## clamp into a neighbouring bar.
  frac = 0.0'f32
  var ch = 0
  while ch < cCwChannels:                 # capped by construction
    var go: Il2CppPtr = nil
    var rt: Il2CppPtr = nil
    var comp: Il2CppPtr = nil
    var kind = 0'i32
    if nkResolve(cwTrackOf(w, ch), "cwHit", go, rt, comp, kind):
      var sx = 0.0'f32
      var sy = 0.0'f32
      var sw = 0.0'f32
      var sh = 0.0'f32
      if nuScreenRectOf(rt, sx, sy, sw, sh):
        if cNuRectContains(sx, sy, sw, sh, mx, my) != 0'i32:
          var f = (mx - sx) / sw
          if not (f > 0.0'f32): f = 0.0'f32
          if f > 1.0'f32: f = 1.0'f32
          frac = f
          return int32(ch)
    ch = ch + 1
  -1'i32

proc cwTickOne(w: var CwWidget; mx, my: float32; held: bool) =
  if not w.used: return
  if not w.armed:
    if not w.armTried: discard cwArm(w)
    return
  # A handle whose element died (scene change, the settings screen closed) must
  # produce a NAMED refusal, not a dereference of a recycled slot. `nuLive`
  # asks nuikit, which knows about RELEASED and STALE-GENERATION as well as
  # Unity's fake-null.
  if not nuLive(w.swatch):
    w.used = false
    w.armed = false
    w.drag = -1'i32
    return
  if not held:
    w.drag = -1'i32
    return
  var frac = 0.0'f32
  if w.drag < 0'i32:
    # PRESS EDGE. Capture only on a hit; a press that started elsewhere on the
    # screen and wandered over the bar must not grab it, which is why the drag
    # channel is captured once and then held rather than re-hit-tested.
    let ch = cwHitChannel(w, mx, my, frac)
    if ch < 0'i32: return
    w.drag = ch
  else:
    # HELD. Re-map along the captured bar only. Leaving the bar vertically or
    # running off its end clamps, exactly like every slider does -- it does not
    # cancel the drag and it does not jump to another channel.
    var go: Il2CppPtr = nil
    var rt: Il2CppPtr = nil
    var comp: Il2CppPtr = nil
    var kind = 0'i32
    if not nkResolve(cwTrackOf(w, int(w.drag)), "cwDrag", go, rt, comp, kind):
      w.drag = -1'i32
      return
    var sx = 0.0'f32
    var sy = 0.0'f32
    var sw = 0.0'f32
    var sh = 0.0'f32
    if not nuScreenRectOf(rt, sx, sy, sw, sh):
      w.drag = -1'i32
      return
    var f = (mx - sx) / sw
    if not (f > 0.0'f32): f = 0.0'f32
    if f > 1.0'f32: f = 1.0'f32
    frac = f
  let before = cwChanValue(w, int(w.drag))
  # QUANTISE TO THE STORED RESOLUTION. The value is persisted as two hex
  # digits, so a drag that moves the pointer without changing the byte must
  # produce NO change at all -- otherwise `swReadBackPage` sees a difference
  # every frame and POSTs a write per frame for a colour that never moved.
  let quant = float32(int(frac * 255.0'f32 + 0.5'f32)) / 255.0'f32
  if quant == before: return
  cwSetChanValue(w, int(w.drag), quant)
  cwApplyVisual(w)
  inc gCwEdits

proc cwTickBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_cw_tick_body", cdecl.} =
  ## THE WHOLE per-frame body, inside the ONE guard `aowl_cw_tick_guarded`
  ## opened. Opens no guard of its own: `aowl_p_p_seh` is not re-entrant and a
  ## nested inner guard disarms the outer one.
  if gCwWidgets.len == 0: return cast[Il2CppPtr](1)
  var anyUsed = false
  var i = 0
  while i < gCwWidgets.len:               # capped: cCwMax
    if gCwWidgets[i].used:
      anyUsed = true
      break
    i = i + 1
  if not anyUsed: return cast[Il2CppPtr](1)

  # Ask the game for the pointer ONCE per frame, not once per widget: these
  # go through a single shared file-scope out-buffer that is explicitly not
  # re-entrant, and one reading is what "this frame" means anyway.
  var mx = 0.0'f32
  var my = 0.0'f32
  let havePos = nuMousePos(mx, my)
  let held = nuMouseDown(0'i32)
  if not havePos:
    # No usable pointer this frame. Release every capture rather than holding a
    # drag against a position we cannot read -- a held drag with a stale
    # position writes the LAST position's value forever.
    var j = 0
    while j < gCwWidgets.len:
      gCwWidgets[j].drag = -1'i32
      j = j + 1
    return cast[Il2CppPtr](1)
  var k = 0
  while k < gCwWidgets.len:               # capped: cCwMax
    cwTickOne(gCwWidgets[k], mx, my, held)
    k = k + 1
  cast[Il2CppPtr](1)

proc cwDrainTick() =
  ## Rides the `EFT.TarkovApplication::Update` drain -- NO detour of its own. A
  ## second detour on one function overwrites the first's trampoline and
  ## silently kills it, so this is a call site on the existing drain, exactly
  ## like `natEspDrainTick`.
  ##
  ## Idle cost with the flag off is one boolean compare and no call into the
  ## game.
  if not gCwOn: return
  if cCwDisabled() != 0'i32: return
  if cNuDisabled() != 0'i32: return
  gCwTicks = gCwTicks + 1
  # THE VERDICT, PRINTED. A three-outcome verdict that nothing ever emits is
  # not a check -- it is a function that could say anything. Every ~300 frames
  # (~5s at 60fps), and only once the state it describes has CHANGED, so the
  # log carries the transitions rather than the same line four hundred times.
  if (gCwTicks mod 300'i64) == 0'i64:
    let v = cwVerdict()
    if v != gCwLastVerdict:
      gCwLastVerdict = v
      okLog v
  if cCwTickGuarded(nil) == nil:
    cCwNoteFault()
    if cCwDisabled() != 0'i32:
      warn "colorwidget: SELF-DISABLED after " & $cCwFaultCount() &
           " fault(s) (cap " & $cCwMaxFaults() & "). The guard caught every " &
           "one and the game survived; the widgets stay on screen and stop " &
           "responding. No further call is made into the game from this path."
    else:
      warn "colorwidget: the guard caught a fault in the tick (" &
           $cCwFaultCount() & " of " & $cCwMaxFaults() & " before this path " &
           "self-disables)"

# ---------------------------------------------------------------------------
# THE VERDICT -- PASS / FAIL / INCONCLUSIVE, never two outcomes
# ---------------------------------------------------------------------------
proc cwVerdict(): string =
  ## Asserts the FINISHED STATE, and states the NEGATIVE where it can, because
  ## a negative can be falsified and a self-comparison cannot:
  ##
  ##   "no built widget's swatch fails to read back the colour it was given"
  ##
  ## INCONCLUSIVE is a real outcome and is returned whenever nothing was
  ## examined -- no widget built, or the flag off. "I could not look" is not a
  ## pass.
  if not gCwOn:
    return "colorwidget VERDICT = INCONCLUSIVE -- the feature is flagged OFF " &
           "(settingsColorWidget), so nothing was built and nothing was " &
           "examined. That is not a pass."
  if gCwBuilt == 0:
    # THE THREE CAUSES, SEPARATED. This branch used to say "either ... or ...",
    # which reads as a mystery and cost a whole session: the true cause was the
    # first one below, and it is a PRECONDITION the host can simply state.
    # `swkColor` rows exist only on MOD pages, and mod pages exist only if
    # `modSettingsRender` fetched them -- the built-in host page is bools only.
    if not gModSetOn:
      return "colorwidget VERDICT = INCONCLUSIVE -- PRECONDITION NOT MET: " &
             "`modSettingsRender` is OFF, so no mod schema was ever fetched " &
             "and the only registered page is the host-flags page, which is " &
             "toggles only. NO `color` ROW CAN EXIST in this configuration, " &
             "so this feature was never asked to build anything. Turn " &
             "modSettingsRender on (with settingsPages) and re-open Settings. " &
             "Nothing was examined; that is not a pass. (built=0 refused=" &
             $gCwRefused & " colourRowsSeen=" & $gModSetColorRowsSeen & ")"
    if gModSetPagesParsed == 0:
      return "colorwidget VERDICT = INCONCLUSIVE -- `modSettingsRender` is on " &
             "but NOT ONE mod schema has parsed yet, so no page could carry a " &
             "colour row. This is a fetch problem, not a colour problem -- see " &
             "the `mod settings render:` lines above. Nothing was examined; " &
             "that is not a pass. (built=0 refused=" & $gCwRefused & ")"
    if gModSetColorRowsSeen == 0:
      return "colorwidget VERDICT = INCONCLUSIVE -- " & $gModSetPagesParsed &
             " mod schema(s) parsed and NOT ONE carried a `color` row, so " &
             "there was nothing for this feature to build. That is a claim " &
             "about the SCHEMAS, not about this code. Nothing was examined; " &
             "that is not a pass. (built=0 refused=" & $gCwRefused & ")"
    if gModSetColorRowsRefused >= gModSetColorRowsSeen:
      return "colorwidget VERDICT = FAIL -- all " & $gModSetColorRowsSeen &
             " colour row(s) seen were REFUSED by the value parser and " &
             "demoted to unbound text rows, so no widget was ever built. The " &
             "row labels above carry the value that would not parse. " &
             "(built=0 refused=" & $gCwRefused & " parserRefused=" &
             $gModSetColorRowsRefused & ")"
    return "colorwidget VERDICT = INCONCLUSIVE -- " & $gModSetColorRowsSeen &
           " colour row(s) reached the renderer and " &
           $(gModSetColorRowsSeen - gModSetColorRowsRefused) & " parsed, but " &
           "no widget has been built (refused=" & $gCwRefused & "). The " &
           "settings screen has most likely not been opened on the tab these " &
           "pages render onto. Nothing was examined; that is not a pass."
  var live = 0
  var mismatched = 0
  var unreadable = 0
  var armed = 0
  var i = 0
  while i < gCwWidgets.len:               # capped: cCwMax
    if gCwWidgets[i].used:
      if gCwWidgets[i].armed: inc armed
      var lr = 0.0'f32
      var lg = 0.0'f32
      var lb = 0.0'f32
      var la = 0.0'f32
      if not cwRowColor(int32(i), lr, lg, lb, la):
        inc unreadable
      else:
        inc live
        # Compared at 8-bit resolution: that is what the value is STORED at,
        # and Unity round-trips a Color through float, so a float-exact
        # comparison would report a mismatch for a colour that is correct.
        if cwByte(lr) != cwByte(gCwWidgets[i].r) or
           cwByte(lg) != cwByte(gCwWidgets[i].g) or
           cwByte(lb) != cwByte(gCwWidgets[i].b):
          inc mismatched
    i = i + 1
  let tail = " (built=" & $gCwBuilt & " refused=" & $gCwRefused &
             " live=" & $live & " armed=" & $armed &
             " unreadable=" & $unreadable & " mismatched=" & $mismatched &
             " edits=" & $gCwEdits & " faults=" & $cCwFaultCount() & ")"
  if unreadable > 0 and live == 0:
    return "colorwidget VERDICT = INCONCLUSIVE -- every built widget's swatch " &
           "was unreadable, so the finished state could not be examined at " &
           "all" & tail
  if mismatched > 0:
    return "colorwidget VERDICT = FAIL -- " & $mismatched & " live swatch(es) " &
           "read back a colour that is NOT the one the setting holds" & tail
  if unreadable > 0:
    return "colorwidget VERDICT = INCONCLUSIVE -- " & $live & " swatch(es) " &
           "read back correctly but " & $unreadable & " could not be read, so " &
           "the negative (\"none is wrong\") is not established" & tail
  if armed == 0:
    return "colorwidget VERDICT = INCONCLUSIVE -- " & $live & " swatch(es) " &
           "render the right colour, but NOT ONE has armed interaction, so " &
           "this establishes the widget is DRAWN and says nothing about " &
           "whether it can be USED" & tail
  "colorwidget VERDICT = PASS -- no live swatch reads back a colour other " &
  "than the one its setting holds, and " & $armed & " of " & $live &
  " have a ScreenSpaceOverlay canvas and armed interaction" & tail

proc bindColorWidget(on: bool) =
  gCwOn = on
  if not on:
    okLog "colorwidget: OFF (settingsColorWidget). A `color` setting renders " &
          "as a labelled stub, exactly as before this feature existed."
    return
  okLog "colorwidget: ON (settingsColorWidget) -- `color` settings render as " &
        "a swatch + R/G/B bars + readout, built from nuikit primitives (no " &
        "game widget is cloned; the settings screen has none to clone). " &
        "Interaction is POLLED off the TarkovApplication::Update drain " &
        "through UnityEngine.Input::GetMouseButton@0x531EBD0 and " &
        "get_mousePosition_Injected@0x531F740, both byte-verified against " &
        "the startup snapshot and both sharedness=UNIQUE. It arms per widget " &
        "only after Graphic.m_Canvas@0x60 reads back a ScreenSpaceOverlay " &
        "Canvas. Cap " & $cCwMax & " widgets; self-disables after " &
        $cCwMaxFaults() & " faults. " & cwAlphaNote & "."
