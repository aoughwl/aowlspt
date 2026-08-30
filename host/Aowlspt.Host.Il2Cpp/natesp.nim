# natesp.nim -- a NATIVE uGUI ESP: contact boxes drawn as REAL Tarkov
# GameObjects, not as our own D3D11 overlay pixels.
#
# WHAT IS NEW HERE AND WHAT IS NOT. Nothing in this file invents a primitive.
# The construction path (`object_new` -> `GameObject::.ctor(string)` ->
# `AddComponent<T>` through the game's own warmed `.data` MethodInfo slot ->
# the `_Injected` layout setters) is nativeui's, and it is HUMAN-CONFIRMED
# visible on build 1.1.0.1.46777. The world census (`GameWorld.RegisteredPlayers`
# +0x1D0, capped, every hop guarded) is botdiag's. The projection
# (`Camera.main` + `WorldToScreenPoint`) and the faction read
# (`Player -> Profile@0x9C0 -> Info@0x48 -> Side@0x48`, refined through
# `Settings@0x78 -> Role@0x10`) are debugui's and botdiag's. This file is the
# WIRING: discovery, a pool, a per-frame placement, and a verdict.
#
# THE THING THAT WAS ACTUALLY MISSING: A CANVAS.
#
# A uGUI element renders only under a Canvas, and there is no Canvas in a raid
# that we may hardcode -- the live UI lives in DontDestroyOnLoad across many
# roots and the raid HUD is not the menu's. So the canvas is DISCOVERED:
#
#   1. Enumerate scene roots the way the inspector's `roots` verb does
#      (`iSceneRoots`, seeded with a live anchor so DontDestroyOnLoad is
#      reachable at all -- `sceneCount`/`GetSceneAt` exclude it by design).
#   2. Breadth-first, capped at AOWL_NE_MAX_NODES nodes and sliced to
#      AOWL_NE_SLICE_MS per frame, ask each node's own Component for a
#      "Canvas" via `Component::GetComponent(String)`. THE STRING OVERLOAD,
#      deliberately: it needs no `System.Type` and therefore touches none of
#      the token-gated exports. The inspector's `findtext` proves that exact
#      call live, thousands of times a frame.
#   3. A candidate is accepted only if ALL of: the component is readable, its
#      native half is alive (`m_CachedPtr` +0x10 non-zero), its GameObject is
#      `activeInHierarchy`, and its RectTransform's `get_rect_Injected` reads
#      back at least AOWL_NE_MIN_CANVAS_PX in both axes. The LARGEST such
#      canvas wins, because the full-screen HUD canvas is the one that renders
#      over the raid.
#   4. IF NOTHING PASSES, THIS REFUSES. `gNeCanvasTr` stays nil, the state goes
#      to NeRefused with AOWL_NE_R_NO_CANVAS, and no box is ever created. There
#      is no fallback to a guessed pointer, because an offset that can read
#      null is not a path.
#
# The same walk collects the two donors nativeui needs and that we otherwise
# could not obtain without reflection: a live GameObject for the class header
# (`nuCreate`'s `klassDonor`) and a live Graphic for `nuRegisterReference`. A
# kind with no reference instance is INCONCLUSIVE in `nuAdd` and returns nil --
# so a missing donor cannot silently produce a wrong-class component.
#
# ALLOCATION PROFILE. The pool is built ONCE, on the frame discovery succeeds:
# one root GameObject plus AOWL_NE_POOL box GameObjects, each with a
# RectTransform and one Graphic, plus the handful of interned strings their
# names need. After that the update path calls only `set_anchoredPosition_
# Injected`, `set_sizeDelta_Injected` and `GameObject::SetActive` -- no
# `object_new`, no `il2cpp_string_new`, no managed allocation at all. Boxes are
# shown and hidden by toggling active; they are never created or destroyed per
# frame. The world census is additionally throttled to one pass in
# AOWL_NE_SCAN_EVERY ticks, while the rects follow the camera EVERY tick.
#
# COLOUR IS NOT PER-FRAME EITHER. The pool is four faction sub-pools of eight.
# `Graphic.m_Color` (+0x28, four floats) is written ONCE per box at build time,
# before that box has ever been enabled and therefore before any mesh exists,
# so no rebuild call is needed and none is made. A contact is placed into the
# sub-pool its faction names; nothing is recoloured while running.
#
# THE EIGHT RULES.
#   1. Every RVA this file reaches is resolved through a table that byte-
#      verifies against the STARTUP prologue snapshot and rejects the
#      `C2 00 00` universal empty-body stub -- nativeui's `nuFn`, debugui's
#      `cDuFn`, and the inspector's `iNavFind`. This file resolves nothing of
#      its own and hardcodes no address.
#   2. Every pointer hop goes through `duOk`/`nuOk` (VirtualQuery) and, where
#      the callee is an icall, additionally through `iUnityAlive`.
#   3. ONE `aowl_p_p_seh` around the whole tick (`cNeTickGuarded`). The body
#      opens NONE of its own: the guard is not re-entrant and a nested inner
#      guard disarms the outer one.
#   4. Capped iteration everywhere: nodes, children, players, pool slots.
#   5. Flag-gated, DEFAULT OFF (`natEsp`), and it additionally requires
#      `nativeUi` -- without the nu* layer it has no way to draw.
#   6. Self-disables after AOWL_NE_MAX_FAULTS faults, with a logged reason.
#   7. No per-frame managed allocation -- see above.
#   8. Never blind-write: the only writes are the one-shot colour store (read
#      back before it is trusted) and the layout setters, all on objects WE
#      allocated.
#
# WHAT THIS FILE MAY NOT CLAIM. That it renders. Nobody can claim that without
# a human looking at the screen. What it CAN establish, and does, is the
# finished state: `neVerdict` reads back each active box's RectTransform and
# counts the ones whose rect is renderable AND on-screen -- a readback, not a
# record of our own writes -- and reports one of exactly three outcomes.

{.emit: """
extern void* aowl_ne_tick_body(void* a);
static void* aowl_ne_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_ne_tick_body, a);
}
""".}
proc cNeTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_ne_tick_guarded", nodecl.}

proc cNeFactionName(f: int32): cstring {.importc: "aowl_ne_faction_name", nodecl.}
proc cNeFactionRgba(f, chan: int32): float32 {.
  importc: "aowl_ne_faction_rgba", nodecl.}
proc cNeRefusalText(r: int32): cstring {.importc: "aowl_ne_refusal_text", nodecl.}
proc cNeNoteFault() {.importc: "aowl_ne_note_fault", nodecl.}
proc cNeFaultCount(): int32 {.importc: "aowl_ne_fault_count", nodecl.}
proc cNeDisabled(): int32 {.importc: "aowl_ne_disabled", nodecl.}
proc cNePool(): int32 {.importc: "aowl_ne_pool", nodecl.}
proc cNeFactions(): int32 {.importc: "aowl_ne_factions", nodecl.}
proc cNePerFaction(): int32 {.importc: "aowl_ne_per_faction", nodecl.}
proc cNeMaxNodes(): int32 {.importc: "aowl_ne_max_nodes", nodecl.}
proc cNeMaxChildren(): int32 {.importc: "aowl_ne_max_children", nodecl.}
proc cNeSliceMs(): int32 {.importc: "aowl_ne_slice_ms", nodecl.}
proc cNeScanEvery(): int32 {.importc: "aowl_ne_scan_every", nodecl.}
proc cNeMinCanvasPx(): float32 {.importc: "aowl_ne_min_canvas_px", nodecl.}
proc cNeOnScreen(x, y, w, h, sw, sh: float32): int32 {.
  importc: "aowl_ne_on_screen", nodecl.}

const
  NeRNone         = 0'i32
  NeROff          = 1'i32
  NeRNoNativeUi   = 2'i32
  NeRNoGetComp    = 3'i32
  NeRNoGameWorld  = 4'i32
  NeRNoCamera     = 5'i32
  NeRNoScreen     = 6'i32
  NeRNoRoots      = 7'i32
  NeRNoCanvas     = 8'i32
  NeRNoGraphic    = 9'i32
  NeRBuildFailed  = 10'i32
  NeRFaulted      = 11'i32
  NeRNoString     = 12'i32

const
  NeVInconclusive = 0'i32
  NeVFail         = 1'i32
  NeVPass         = 2'i32

const
  NeIdle     = 0
  NeDiscover = 1
  NeBuild    = 2
  NeRun      = 3
  NeRefused  = 4

const NeMaxPool = 32          ## must equal AOWL_NE_POOL; asserted at bind
const NeMaxContacts = 64      ## players read per census pass
const NeOffGraphicColor  = 0x28'i32

# ---- flags. Both default OFF. -------------------------------------------
var gNeOn = false
var gNeDiag = false

# ---- state ---------------------------------------------------------------
var gNeState = NeIdle
var gNeWhy = NeROff
var gNeTicks = 0'i64
var gNeCam: Il2CppPtr = nil
var gNeCamAt = 0'i64

var gNeCanvasGo: Il2CppPtr = nil     ## the discovered Canvas's GameObject
var gNeCanvasTr: Il2CppPtr = nil     ## its RectTransform -- our parent
var gNeCanvasW = 0'f32
var gNeCanvasH = 0'f32
var gNeGraphicDonor: Il2CppPtr = nil ## a live Graphic, for nuRegisterReference

var gNeRootGo: Il2CppPtr = nil
var gNeRootTr: Il2CppPtr = nil
var gNeBoxGo: array[NeMaxPool, Il2CppPtr]
var gNeBoxRt: array[NeMaxPool, Il2CppPtr]
var gNeBoxActive: array[NeMaxPool, bool]
var gNeBuilt = 0

# the census, in FIXED arrays -- no seq, so no allocation per pass
var gNeCx: array[NeMaxContacts, float64]
var gNeCy: array[NeMaxContacts, float64]
var gNeCz: array[NeMaxContacts, float64]
var gNeCf: array[NeMaxContacts, int32]
var gNeCn = 0
var gNeContactsEver = 0'i64

# the last verdict, so the diag and the report agree by construction
var gNeVerdict = NeVInconclusive
var gNeShown = 0
var gNeOnScreen = 0
var gNeDropped = 0
var gNeDiagAt = 0'u64

# ---- discovery walk state (breadth-first, sliced across frames) ----------
var gNeQueue: seq[Il2CppPtr] = @[]
var gNeHead = 0
var gNeBudget = 0
var gNeSeeded = false
var gNeBestArea = 0'f32
var gNeVisited = 0

proc neOk(p: Il2CppPtr; n: int32): bool =
  p != nil and cIsReadable(p, n) != 0'i32

proc neF(v: float32): string = formatFloat(float64(v), ffDecimal, 1)

proc neRefuse(why: int32) =
  ## Every failure path announces itself, once, with the measured reason.
  if gNeState == NeRefused and gNeWhy == why: return
  gNeState = NeRefused
  gNeWhy = why
  gNeVerdict = NeVInconclusive
  warn "natesp: canvas discovery REFUSED -- " & readCString(cNeRefusalText(why))

# ---------------------------------------------------------------------------
# THE RAID GATE
#
# `GameWorld` exists is NOT "the player is in the raid": RegisterPlayer fires
# for every bot during scene LOAD, roughly two minutes before deployment.
# `EFT.GameWorld::OnGameStarted` @0x2508000 is the real deploy signal but a
# 14-byte prologue steal crosses its `je` and the detour engine refuses
# relative branches -- so this gates on state it can READ instead: a live
# GameWorld, a readable MainPlayer, a non-null Camera.main, and a measured back
# buffer. Camera.main is the discriminating one: it is null in the menu and on
# the loading screen and non-null once the raid is actually being drawn.
# ---------------------------------------------------------------------------
proc neCamera(): Il2CppPtr =
  let fnCam = cDuFn(DuCameraMain)
  if fnCam == nil: return nil
  if (gNeTicks - gNeCamAt) >= 30 or (gNeCam != nil and not duOk(gNeCam, 0x20'i32)):
    gNeCam = cDuCallPV(fnCam)
    gNeCamAt = gNeTicks
    if not duOk(gNeCam, 0x20'i32): gNeCam = nil
  gNeCam

proc neRaidGate(sw, sh: var float64): int32 =
  ## NeRNone when every readable precondition holds; otherwise the reason.
  let gw = gDuGameWorld
  if not duOk(gw, cBdOffMainPlayer() + 8'i32): return NeRNoGameWorld
  let you = cReadPtrAt(gw, cBdOffMainPlayer())
  if not duOk(you, 0x20'i32) or not bdSanePtr(you): return NeRNoGameWorld
  if neCamera() == nil: return NeRNoCamera
  if not duCanvasSize(sw, sh): return NeRNoScreen
  NeRNone

# ---------------------------------------------------------------------------
# DISCOVERY
# ---------------------------------------------------------------------------
var gNeTypeCanvas: Il2CppPtr = nil
var gNeTypeImage: Il2CppPtr = nil

proc neInternTypes(): bool =
  ## The two managed strings `Component::GetComponent(String)` needs, interned
  ## ONCE into nativeui's bounded intern table. Doing this per node would be a
  ## per-frame managed allocation on the walk.
  if gNeTypeCanvas == nil: gNeTypeCanvas = cNuIntern("Canvas")
  if gNeTypeImage == nil: gNeTypeImage = cNuIntern("UnityEngine.UI.Image")
  gNeTypeCanvas != nil and gNeTypeImage != nil

proc neGetComponent(fn, tr, typeStr: Il2CppPtr): Il2CppPtr =
  ## One guarded `Component::GetComponent(String)`. `tr` is a Transform by
  ## contract (the queue is seeded and fed only from Transforms), which is why
  ## the Component overload is the right one here without a GameObject branch.
  if fn == nil or typeStr == nil: return nil
  if not duOk(tr, 0x20'i32) or not iUnityAlive(tr): return nil
  let c = cast[Il2CppPtr](cInspUPP(fn, tr, typeStr, nil))
  if not duOk(c, 0x20'i32) or not iUnityAlive(c): return nil
  c

proc neCanvasRect(canvas: Il2CppPtr; w, h: var float32): bool =
  ## A canvas that does not read back a real pixel rect is not a canvas we may
  ## parent to. This is a READBACK from the game, through the sret `_Injected`
  ## getter -- not an assumption and not a constant.
  w = 0'f32
  h = 0'f32
  let go = nuGameObjectOf(canvas)
  if go == nil: return false
  if not nuActiveInHierarchy(go): return false
  let tr = nuTransformOf(go)
  if tr == nil: return false
  let (okR, _, _, rw, rh) = nuGetRect(tr)
  if not okR: return false
  if not (rw >= cNeMinCanvasPx()) or not (rh >= cNeMinCanvasPx()): return false
  w = rw
  h = rh
  true

proc neSeed(): bool =
  ## Seed the breadth-first queue with every scene root we can legitimately
  ## reach, INCLUDING DontDestroyOnLoad -- which SceneManager excludes by
  ## design, so it is reached through a live anchor instead.
  gNeQueue = @[]
  gNeHead = 0
  gNeBudget = int(cNeMaxNodes())
  gNeVisited = 0
  gNeBestArea = 0'f32
  var roots: seq[Il2CppPtr] = @[]
  discard iSceneRoots(roots, false, gSplUpdatePreloader)
  for g in roots:
    if not duOk(g, 0x20'i32): continue
    let tr = nuTransformOf(g)
    if tr != nil: gNeQueue.add tr
  gNeQueue.len > 0

proc neDiscoverStep() =
  ## One frame's slice. Returns by mutating the state machine; the walk is
  ## bounded twice -- by the node budget in total and by the millisecond slice
  ## per frame -- so it can neither run away nor stall a frame.
  if not neInternTypes():
    neRefuse(NeRNoString)
    return
  var fnGet: Il2CppPtr = nil
  if not iNavFindQuiet("Component::GetComponent(String)", fnGet) or fnGet == nil:
    neRefuse(NeRNoGetComp)
    return
  if not gNeSeeded:
    if not neSeed():
      neRefuse(NeRNoRoots)
      return
    gNeSeeded = true
    okLog "natesp: canvas discovery started -- " & $gNeQueue.len &
          " scene roots seeded (DontDestroyOnLoad included via the live " &
          "anchor), budget " & $gNeBudget & " nodes, " & $int(cNeSliceMs()) &
          "ms per frame. Nothing is parented until a canvas PASSES."
  let started = cNowMs()
  var spent = 0
  while gNeHead < gNeQueue.len:
    if gNeBudget <= 0: break
    if (spent and 31) == 0 and cNowMs() - started > uint64(cNeSliceMs()):
      return                      # more next frame; state unchanged
    let cur = gNeQueue[gNeHead]
    inc gNeHead
    inc spent
    dec gNeBudget
    if not duOk(cur, 0x20'i32) or not iUnityAlive(cur): continue
    inc gNeVisited
    let canvas = neGetComponent(fnGet, cur, gNeTypeCanvas)
    if canvas != nil:
      var cw = 0'f32
      var ch = 0'f32
      if neCanvasRect(canvas, cw, ch):
        let area = cw * ch
        if area > gNeBestArea:
          gNeBestArea = area
          gNeCanvasGo = nuGameObjectOf(canvas)
          gNeCanvasTr = nuTransformOf(gNeCanvasGo)
          gNeCanvasW = cw
          gNeCanvasH = ch
    if gNeGraphicDonor == nil:
      let img = neGetComponent(fnGet, cur, gNeTypeImage)
      if img != nil: gNeGraphicDonor = img
    var n = 0
    if iChildCount(cur, n):
      var k = 0
      while k < n and k < int(cNeMaxChildren()):
        let c = iChildAt(cur, k)
        if c != nil: gNeQueue.add c
        inc k
  # The walk is FINISHED (queue drained or budget spent). Decide, out loud.
  if gNeCanvasTr == nil or gNeCanvasGo == nil:
    okLog "natesp: the walk visited " & $gNeVisited & " node(s) with " &
          $gNeBudget & " of the node budget left and found no qualifying " &
          "Canvas. A canvas qualifies only if it is alive, activeInHierarchy " &
          "and its rect READS BACK at least " & neF(cNeMinCanvasPx()) & "px."
    neRefuse(NeRNoCanvas)
    return
  if gNeGraphicDonor == nil:
    neRefuse(NeRNoGraphic)
    return
  okLog "natesp: canvas ACCEPTED at 0x" & hexOf(cast[uint64](gNeCanvasGo)) &
        " -- rect reads back " & neF(gNeCanvasW) & "x" & neF(gNeCanvasH) &
        " (the largest qualifying of " & $gNeVisited & " nodes walked), name=\"" &
        iObjName(gNeCanvasGo) & "\". Graphic donor 0x" &
        hexOf(cast[uint64](gNeGraphicDonor)) & "."
  gNeState = NeBuild

# ---------------------------------------------------------------------------
# THE POOL -- built ONCE
# ---------------------------------------------------------------------------
proc neColour(box: Il2CppPtr; faction: int32): bool =
  ## Graphic.m_Color at +0x28, four floats, written ONCE before this box has
  ## ever been enabled -- so before any mesh exists and no rebuild is needed.
  ##
  ## The readback below is honest about what it is: it proves the STORE LANDED
  ## (the four floats are not still zero), which is what catches a guarded write
  ## silently refusing. It does NOT prove the colour reaches the screen -- that
  ## is what `neVerdict` is for, and even that stops short of "a human saw it".
  if not neOk(box, NeOffGraphicColor + 16'i32): return false
  var i = 0'i32
  while i < 4'i32:
    if cDuWriteF32(box, NeOffGraphicColor + i * 4'i32,
                   float64(cNeFactionRgba(faction, i))) == 0'i32:
      return false
    inc i
  cReadI32At(duPtrAdd(box, NeOffGraphicColor + 12'i32)) != 0'i32

proc neDestroyPool() =
  var i = 0
  while i < NeMaxPool:
    if gNeBoxGo[i] != nil: discard nuDestroy(gNeBoxGo[i])
    gNeBoxGo[i] = nil
    gNeBoxRt[i] = nil
    gNeBoxActive[i] = false
    inc i
  if gNeRootGo != nil: discard nuDestroy(gNeRootGo)
  gNeRootGo = nil
  gNeRootTr = nil
  gNeBuilt = 0

proc neBuildPool(): bool =
  ## One root plus AOWL_NE_POOL boxes, all of it here and never again. The
  ## class donor is the DISCOVERED canvas's GameObject -- a live object we
  ## walked to and validated, which is the only reflection-free way to obtain
  ## the GameObject class pointer.
  if not nuRegisterReference(NuKindImage, gNeGraphicDonor):
    warn "natesp: the Image reference instance was refused, so nuAdd could " &
         "only ever answer INCONCLUSIVE for the box component. Refusing to " &
         "build a pool of components whose class was never checked."
    return false
  gNeRootGo = nuCreate("aowlspt-esp-root", gNeCanvasGo)
  if gNeRootGo == nil: return false
  if nuAdd(gNeRootGo, NuKindRectTransform) == nil: return false
  gNeRootTr = nuTransformOf(gNeRootGo)
  if gNeRootTr == nil: return false
  if not nuParentAligned(gNeRootGo, gNeCanvasGo): return false
  # full-stretch, so box positions are canvas pixels with the origin bottom-left
  if not nuLayout(gNeRootTr, 0'f32, 0'f32, 0'f32, 0'f32, 0'f32, 0'f32,
                  gNeCanvasW, gNeCanvasH, 0'f32, 0'f32): return false
  var i = 0
  while i < NeMaxPool:
    let faction = int32(i div int(cNePerFaction()))
    let go = nuCreate("aowlspt-esp-box", gNeCanvasGo)
    if go == nil: return false
    if nuAdd(go, NuKindRectTransform) == nil: return false
    let rt = nuTransformOf(go)
    if rt == nil: return false
    let img = nuAdd(go, NuKindImage)
    if img == nil: return false
    if not nuParentAligned(go, gNeRootGo): return false
    # anchored to the canvas's bottom-left, pivot centred: anchoredPosition is
    # then a plain screen pixel and matches WorldToScreenPoint's own origin.
    if not nuLayout(rt, 0'f32, 0'f32, 0'f32, 0'f32, 0.5'f32, 0.5'f32,
                    24'f32, 48'f32, 0'f32, 0'f32): return false
    if not neColour(img, faction): return false
    discard nuSetActive(go, false)
    gNeBoxGo[i] = go
    gNeBoxRt[i] = rt
    gNeBoxActive[i] = false
    inc gNeBuilt
    inc i
  true

# ---------------------------------------------------------------------------
# THE CENSUS -- into fixed arrays, throttled, capped
# ---------------------------------------------------------------------------
proc neFactionOf(pl: Il2CppPtr): int32 =
  ## EPlayerSide 1=Usec, 2=Bear, 4=Savage -- NOT 3. Savage is split by
  ## WildSpawnType so a boss/raider/rogue does not read as a plain scav.
  var side = 0'i32
  var role = 0'i32
  bdReadSideRole(pl, side, role)
  case int(side)
  of 1: return 0'i32          # USEC
  of 2: return 1'i32          # BEAR
  else: discard
  let rn = duRoleName(role)
  if rn.len == 0: return 2'i32
  if iContains(iLower(rn), "boss") or iContains(iLower(rn), "raider") or
     iContains(iLower(rn), "rogue") or iContains(iLower(rn), "follower"):
    return 3'i32
  2'i32

proc neScan() =
  ## `GameWorld.RegisteredPlayers` +0x1D0, capped at NeMaxContacts, every hop
  ## guarded, read-only. Fills FIXED arrays -- botdiag's discipline with the
  ## logging and the seq allocation both removed.
  gNeCn = 0
  let gw = gDuGameWorld
  if not duOk(gw, cBdOffRegPlayers() + 8'i32): return
  let lst = cReadPtrAt(gw, cBdOffRegPlayers())
  if not duOk(lst, cBdOffListSize() + 4'i32): return
  let arr = cReadPtrAt(lst, cBdOffListItems())
  let size = cReadI32At(duPtrAdd(lst, cBdOffListSize()))
  if not duOk(arr, cBdOffArrElems() + 8'i32) or size <= 0'i32: return
  let n = (if size > int32(NeMaxContacts): int32(NeMaxContacts) else: size)
  var i = 0'i32
  while i < n:
    if gNeCn >= NeMaxContacts: break
    let slot = duPtrAdd(arr, cBdOffArrElems() + i * 8'i32)
    inc i
    if cIsReadable(slot, 8'i32) == 0'i32: continue
    let pl = cReadPtrAt(slot, 0'i32)
    if pl == nil or not bdSanePtr(pl): continue
    if bdIsYou(pl): continue
    var posOk = false
    var x = 0.0
    var y = 0.0
    var z = 0.0
    duPlayerPos(pl, posOk, x, y, z)
    if not posOk: continue
    gNeCx[gNeCn] = x
    gNeCy[gNeCn] = y
    gNeCz[gNeCn] = z
    gNeCf[gNeCn] = neFactionOf(pl)
    inc gNeCn
  gNeContactsEver = gNeContactsEver + int64(gNeCn)

# ---------------------------------------------------------------------------
# THE UPDATE -- show/hide by toggling active, place by the _Injected setters
# ---------------------------------------------------------------------------
proc nePlace(sw, sh: float64) =
  let fnW2S = cDuFn(DuWorldToScreen)
  let cam = neCamera()
  gNeShown = 0
  gNeDropped = 0
  var used: array[4, int] = [0, 0, 0, 0]
  if fnW2S == nil or cam == nil:
    # hide everything rather than leave the last frame's boxes frozen on screen
    var k = 0
    while k < gNeBuilt:
      if gNeBoxActive[k]:
        discard nuSetActive(gNeBoxGo[k], false)
        gNeBoxActive[k] = false
      inc k
    return
  var c = 0
  while c < gNeCn:
    let faction = int(gNeCf[c])
    inc c
    if faction < 0 or faction >= 4: continue
    let ci = c - 1
    if cDuWorldToScreen(fnW2S, cam, gNeCx[ci], gNeCy[ci], gNeCz[ci]) == 0'i32:
      continue
    if cDuScreenZ() <= 0.0: continue          # behind the camera
    if used[faction] >= int(cNePerFaction()):
      inc gNeDropped
      continue
    let idx = faction * int(cNePerFaction()) + used[faction]
    inc used[faction]
    if idx < 0 or idx >= gNeBuilt: continue
    let rt = gNeBoxRt[idx]
    if rt == nil: continue
    # A nearer contact gets a bigger box. Bounded so nuLayout's renderability
    # check can never be handed an absurd extent.
    let depth = cDuScreenZ()
    var boxH = 900.0 / (if depth < 5.0: 5.0 else: depth)
    if boxH < 6.0: boxH = 6.0
    if boxH > 220.0: boxH = 220.0
    let boxW = boxH * 0.45
    if not nuSetV2(rt, NuTRtSetSizeDelta, float32(boxW), float32(boxH)): continue
    if not nuSetV2(rt, NuTRtSetAnchoredPos,
                   float32(cDuScreenX()), float32(cDuScreenY())): continue
    if not gNeBoxActive[idx]:
      if not nuSetActive(gNeBoxGo[idx], true): continue
      gNeBoxActive[idx] = true
    inc gNeShown
  # hide the tail of every sub-pool that this frame did not use
  var g = 0
  while g < 4:
    var s = used[g]
    while s < int(cNePerFaction()):
      let idx = g * int(cNePerFaction()) + s
      if idx < gNeBuilt and gNeBoxActive[idx]:
        discard nuSetActive(gNeBoxGo[idx], false)
        gNeBoxActive[idx] = false
      inc s
    inc g

# ---------------------------------------------------------------------------
# THE VERDICT -- §9b. Three outcomes, and PASS is a READBACK.
#
# "The callback ran and returned" is not evidence. An existing maps diag makes
# the point for us: it reported that its draw callback "ran 23358 time(s) and
# drew NOTHING every time". So PASS here is not "we called SetActive(true) N
# times". It is: for each box we believe is active, ask the GAME for its
# `activeInHierarchy` and for its RectTransform's anchoredPosition and
# sizeDelta, and count only those that come back renderable AND on-screen.
#
# That is falsifiable in both directions. It fails if the boxes are inactive,
# if their rects collapsed to zero, if they landed off-screen, or if the whole
# pool was silently destroyed by a scene change. It cannot be satisfied by our
# own bookkeeping, because none of the three reads is a variable we wrote.
# ---------------------------------------------------------------------------
proc neVerdict(sw, sh: float64): int32 =
  gNeOnScreen = 0
  if gNeState != NeRun or gNeBuilt <= 0 or gNeCanvasTr == nil:
    return NeVInconclusive
  var i = 0
  while i < gNeBuilt:
    if gNeBoxActive[i] and gNeBoxGo[i] != nil and gNeBoxRt[i] != nil:
      if nuActiveInHierarchy(gNeBoxGo[i]):
        let (okP, px, py) = nuGetPos(gNeBoxRt[i])
        let (okS, bw, bh) = nuGetSize(gNeBoxRt[i])
        if okP and okS and
           cNeOnScreen(px, py, bw, bh, float32(sw), float32(sh)) != 0'i32:
          inc gNeOnScreen
    inc i
  if gNeOnScreen > 0: return NeVPass
  if gNeCn > 0: return NeVFail
  NeVInconclusive

proc neVerdictLine(sw, sh: float64): string =
  case int(gNeVerdict)
  of 2:
    "natesp VERDICT PASS -- canvas found, pool built, and " & $gNeOnScreen &
      " box(es) read BACK from the game as activeInHierarchy with a " &
      "renderable on-screen rect this frame (of " & $gNeShown &
      " placed, " & $gNeCn & " contact(s), " & $gNeDropped &
      " over the per-faction pool). This is the finished state, not a record " &
      "of our own writes -- but it is still not proof a human can SEE them."
  of 1:
    "natesp VERDICT FAIL -- contacts exist but ZERO boxes read back active " &
      "with a valid on-screen rect. contacts=" & $gNeCn & " placed=" &
      $gNeShown & " built=" & $gNeBuilt & " canvas=" & neF(gNeCanvasW) & "x" &
      neF(gNeCanvasH) & " screen=" & duFmt0(sw) & "x" & duFmt0(sh) &
      ". The pool exists and the placement ran; the finished state is empty."
  else:
    "natesp VERDICT INCONCLUSIVE -- " & readCString(cNeRefusalText(gNeWhy)) &
      "  (state=" & $gNeState & " built=" & $gNeBuilt & " contacts=" & $gNeCn &
      " faults=" & $int(cNeFaultCount()) & "). I could not look; that is NOT " &
      "a pass."

# ---------------------------------------------------------------------------
# THE TICK -- one body, one guard, ridden on the existing Update drain
# ---------------------------------------------------------------------------
proc neTickBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_ne_tick_body", cdecl.} =
  var sw = 0.0
  var sh = 0.0
  let gate = neRaidGate(sw, sh)
  if gate != NeRNone:
    # NOT a refusal to remember: the menu and the loading screen are legitimate
    # states. Drop back to waiting and tear nothing down unless the canvas
    # itself died -- which is the one thing that must not be used again.
    if gNeState == NeRun and not duOk(gNeCanvasTr, 0x20'i32):
      neDestroyPool()
      gNeCanvasGo = nil
      gNeCanvasTr = nil
      gNeSeeded = false
      gNeState = NeIdle
    gNeWhy = gate
    gNeVerdict = NeVInconclusive
    gNeCn = 0
    return cast[Il2CppPtr](1)
  case gNeState
  of NeIdle:
    gNeWhy = NeRNone
    gNeState = NeDiscover
  of NeDiscover:
    neDiscoverStep()
  of NeBuild:
    if neBuildPool():
      okLog "natesp: pool BUILT -- " & $gNeBuilt & " box(es) in " &
            $int(cNeFactions()) & " faction sub-pools of " &
            $int(cNePerFaction()) & ", parented under the discovered canvas. " &
            "Every one is inactive and coloured; from here the update path " &
            "allocates NOTHING and only toggles active and moves rects."
      gNeState = NeRun
    else:
      neDestroyPool()
      neRefuse(NeRBuildFailed)
  of NeRun:
    if not duOk(gNeCanvasTr, 0x20'i32) or not nuActiveInHierarchy(gNeCanvasGo):
      # the raid canvas went away (scene change): drop the pool and rediscover
      neDestroyPool()
      gNeCanvasGo = nil
      gNeCanvasTr = nil
      gNeSeeded = false
      gNeState = NeIdle
      return cast[Il2CppPtr](1)
    if (gNeTicks mod int64(cNeScanEvery())) == 0: neScan()
    nePlace(sw, sh)
    gNeVerdict = neVerdict(sw, sh)
  else:
    discard
  cast[Il2CppPtr](1)

proc natEspDrainTick() =
  ## Rides the `EFT.TarkovApplication::Update` drain (slot alias -- NO second
  ## detour; a second detour on one function overwrites the first's trampoline
  ## and silently kills it). Idle cost when the flag is off is one compare and
  ## no call into the game.
  if not gNeOn: return
  if cNeDisabled() != 0'i32:
    if gNeWhy != NeRFaulted: neRefuse(NeRFaulted)
    return
  if cNuDisabled() != 0'i32:
    if gNeWhy != NeRNoNativeUi: neRefuse(NeRNoNativeUi)
    return
  gNeTicks = gNeTicks + 1
  if cNeTickGuarded(nil) == nil:
    cNeNoteFault()
    warn "natesp: the guarded tick FAULTED (" & $int(cNeFaultCount()) & " of " &
         "the budget). State=" & $gNeState & "; self-disables at the cap."
    return
  if gNeDiag and (cNowMs() - gNeDiagAt) > 5000'u64:
    gNeDiagAt = cNowMs()
    var sw = 0.0
    var sh = 0.0
    discard duCanvasSize(sw, sh)
    okLog neVerdictLine(sw, sh)

proc bindNativeEsp*(verbose: bool) =
  ## Reports readiness once. Installs NO detour and resolves NO address of its
  ## own -- every RVA it reaches was byte-verified against the startup prologue
  ## snapshot by nativeui, debugui or the inspector's nav table before this ran.
  if not gNeOn: return
  if int(cNePool()) != NeMaxPool:
    warn "natesp: AOWL_NE_POOL and NeMaxPool disagree (" & $int(cNePool()) &
         " vs " & $NeMaxPool & "); refusing to arm rather than index a fixed " &
         "array by a cap it does not match."
    gNeOn = false
    return
  if not gNuOn:
    warn "natesp: natEsp is set but nativeUi is OFF. The nu* primitives are " &
         "the only way this draws anything, so it is NOT armed."
    gNeOn = false
    return
  okLog "natesp: the native uGUI ESP is ARMED. It will discover a raid canvas " &
        "at runtime (Component::GetComponent(String) over the scene roots, " &
        "DontDestroyOnLoad included) and REFUSE if none qualifies -- it never " &
        "parents to a guessed pointer. Pool of " & $NeMaxPool & " Image boxes, " &
        "built once, shown by toggling active. Verdict every 5s with natEspDiag."
