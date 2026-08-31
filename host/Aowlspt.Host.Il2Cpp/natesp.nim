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
proc cNeMaxDepth(): int32 {.importc: "aowl_ne_max_depth", nodecl.}
proc cNeMaxDiscFaults(): int32 {.importc: "aowl_ne_max_disc_faults", nodecl.}
proc cNeMaxSeedTries(): int32 {.importc: "aowl_ne_max_seed_tries", nodecl.}
proc cNeMaxSeedSkips(): int32 {.importc: "aowl_ne_max_seed_skips", nodecl.}
proc cNeSliceMs(): int32 {.importc: "aowl_ne_slice_ms", nodecl.}
proc cNeScanEvery(): int32 {.importc: "aowl_ne_scan_every", nodecl.}
proc cNeMinCanvasPx(): float32 {.importc: "aowl_ne_min_canvas_px", nodecl.}
proc cNeCanvasSortOrder(): int32 {.
  importc: "aowl_ne_canvas_sort_order", nodecl.}
proc cNeCanvasSettleTicks(): int32 {.
  importc: "aowl_ne_canvas_settle_ticks", nodecl.}
proc cNeUiLayer(): int32 {.importc: "aowl_ne_ui_layer", nodecl.}
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
  NeRDiscFaulted  = 13'i32
  NeRSeedTries    = 14'i32
  NeRCanvasDonor  = 15'i32
  NeRCanvasCreate = 16'i32
  NeRCanvasUnverified = 17'i32

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
  NeSettle   = 5   ## our canvas exists; waiting for it to READ BACK sane

# THE CANVAS ORIGIN -- three outcomes, and the reason this const block exists.
#
# `gNeCanvasGo != nil` used to be the whole story, and it could not say WHERE
# the canvas came from. Now that natesp can build one, "we are drawing" has two
# very different causes and one failure, and the verdict line has to be able to
# name which: parenting into the game's own HUD canvas and parenting into ours
# fail in different ways and are fixed in different places.
const
  NeOriginNone    = 0'i32   ## nothing bound
  NeOriginFound   = 1'i32   ## an EXISTING canvas, discovered
  NeOriginCreated = 2'i32   ## OURS, built from scratch

proc neOriginName(o: int32): string =
  case int(o)
  of 1: "FOUND(existing)"
  of 2: "CREATED(ours)"
  else: "NONE"

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

# ---- OUR OWN CANVAS ------------------------------------------------------
# `gNeOwnCanvasGo` is set ONLY when we created it, and it is what teardown
# destroys. It is deliberately a SECOND variable rather than a flag on
# gNeCanvasGo: destroying a canvas we merely FOUND would take the game's HUD
# down with it, and the two must never be one pointer with a boolean beside it.
var gNeCanvasOrigin = NeOriginNone
var gNeOwnCanvasGo: Il2CppPtr = nil   ## GAMEOBJECT -- ours, and ours to destroy
var gNeOwnCanvasComp: Il2CppPtr = nil ## the CANVAS COMPONENT on it
var gNeOwnCanvasTr: Il2CppPtr = nil   ## its RECTTRANSFORM
var gNeSettleFrom = 0'i64             ## tick the settle wait started
var gNeSettleReads = 0                ## readback attempts made
var gNeSettleLast = ""                ## what the last readback actually said
var gNeCreateTried = false            ## creation attempted this discovery pass
var gNeParentLine = "parent readback not run yet"
  ## The finished-tree ownership negative from `neBuildPool`, carried into the
  ## verdict so a PASS can never be read as proof of ownership it did not test.

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
var gNeDepth: seq[int32] = @[]       ## depth of the node at the same index
var gNeHead = 0
var gNeBudget = 0
var gNeSeeded = false
var gNeBestArea = 0'f32
var gNeVisited = 0

# ---- the discovery ledger, reported verbatim in the diag line -------------
var gNeSeedCount = 0     ## scene roots that survived the liveness check
var gNeSeedDead = 0      ## scene roots that were fake nulls at seed time
var gNeFakeNull = 0      ## nodes SKIPPED because their native half was gone
var gNeCandidates = 0    ## nodes that had a Canvas component at all
var gNeRejected = 0      ## Canvases that failed the acceptance rule
var gNeDeepest = 0       ## deepest level actually reached
var gNeTruncated = 0     ## children NOT queued because of the depth cap
var gNeDiscFaults = 0    ## faults charged to discovery, not to steady state

# ---- THE SEED LEDGER -----------------------------------------------------
#
# MEASURED (integ-beta6 @4b66faf, fully loaded Woods raid, natEsp+natEspDiag
# ON): the verdict line read `visited=0 fakeNullsSkipped=0 budgetLeft=20000
# head=0/0 discFaults=24`. The breadth-first walk never popped a node and never
# spent a unit of budget -- so it was NOT the walk that faulted and NOT a fake
# null. It faulted in SEEDING, before the queue existed. The message still said
# "the canvas WALK faulted", which is honest about the fault and useless about
# where: CLAUDE.md 9b, a diagnostic that cannot distinguish two causes.
#
# So the seed now names its own step. `gNeSeedStep` is set BEFORE each call
# that can fault, never after, so the value surviving a fault is the step that
# faulted rather than the last one that succeeded.
const
  NeSeedIdle      = 0
  NeSeedAnchor    = 1   ## obtaining the durable DontDestroyOnLoad anchor
  NeSeedEnum      = 2   ## iSceneRoots -- SceneManager + the anchor's scene
  NeSeedConvert   = 3   ## GameObject -> Transform for each root obtained
  NeSeedDone      = 4

var gNeSeedStep = NeSeedIdle
var gNeSeedTries = 0        ## seed attempts made (bounded by cNeMaxSeedTries)
var gNeSeedRootsGot = 0     ## roots iSceneRoots handed back, before liveness
var gNeSeedAnchor = false   ## did we obtain a durable anchor at all?

# ---- FAULTED IS NOT DEAD ---------------------------------------------------
#
# MEASURED (integ-beta6 @8829a49, loaded raid): `rootsObtained=178
# liveRootsSeeded=0 rootsSkippedDead=0 discFaults=24`. Zero seeded AND zero
# classified dead is not a classification result at all -- every root FAULTED,
# and the ledger had no field that could say so, so the two outcomes collapsed
# into one indistinguishable pair of zeros. CLAUDE.md 9b in its purest form.
#
# `gNeSeedFaulted` is that missing third outcome. It is charged from the
# TICK-LEVEL fault handler, because the guard is not re-entrant and a per-root
# guard nested inside the tick's would DISARM the tick's -- so the seed instead
# records the root index it is IN FLIGHT on before touching it, and the fault
# handler converts that index into a permanent skip. The next attempt steps
# over it. One bad root can therefore no longer consume the whole feature.
var gNeSeedFaulted = 0        ## roots that FAULTED conversion (not "dead")
var gNeSeedInFlight = -1      ## index of the root being converted right now
var gNeSeedSkip: seq[int32] = @[]   ## indices proven to fault; capped
var gNeSeedGiven = false      ## the try cap was reached; stop re-enumerating
var gNeSeedGoSeen = 0         ## roots that arrived as an UNTRANSLATED GameObject

# ---- WHY THE WALK IS TWO-PHASE ------------------------------------------
#
# MEASURED (integ-beta6 @1288f5a, DEPLOYED raid, seed fixed): `anchor=yes
# rootsObtained=178 liveRootsSeeded=178 rootsFaulted=0` and then
# `visited=15296 candidates=0 deepest=3/8 budgetLeft=4704 head=15296/30170
# discFaults=0`. NOTHING faulted. The walk simply DROWNED IN BREADTH: a
# loaded raid accumulates roots from every SceneManager scene, and the
# overwhelming majority of those 178 are MAP GEOMETRY. A flat breadth-first
# over all of them spends the entire node budget three levels deep in
# terrain and never reaches the UI at all -- `deepest=3/8` says depth was
# never the binding constraint.
#
# The UI is not in those scenes. It is in DontDestroyOnLoad, which
# SceneManager does not list and which `iSceneRoots` appends LAST, i.e. in
# exactly the worst position for a flat FIFO. So the search is now SCOPED,
# not merely ordered:
#
#   PHASE A  the anchor's own scene (DontDestroyOnLoad) ONLY, walked to the
#            full depth cap with the full node budget. ~16 roots, so this
#            is cheap and it is where `Common UI`, `Menu UI`, `Preloader
#            UI`, `Environment UI`, `Login UI`, `Canvas` and `Game Scene`
#            actually live.
#   PHASE B  everything else, entered ONLY if phase A finished and produced
#            no qualifying canvas, with its own fresh budget.
#
# Within each phase, roots whose NAME looks like UI are searched first --
# names are one guarded `Object::get_name` per ROOT (178 max, once, at seed
# time, inside the existing one-time allocating seed), never per node.
#
# The point of the phase split is the LEDGER, not the speed. `candidates=0`
# alone cannot distinguish "searched the places the UI lives and there was
# no canvas" from "never got there". Phase A reports its own scope, its own
# exhaustiveness, and THE NAMES OF THE ROOTS IT SEARCHED, so those two
# outcomes are now different lines.
const
  NeMaxRootUniverse  = 512  ## hard cap on roots considered, both phases
  NeMaxRootNameChars = 480  ## cap on the reported phase-A root-name list
  NePhaseA = 0   ## DontDestroyOnLoad (the anchor's scene)
  NePhaseB = 1   ## every other loaded scene's roots

var gNePhase = NePhaseA
var gNePhaseBRoots: seq[Il2CppPtr] = @[]   ## deferred; seeded only if A fails
var gNePhaseARootCount = 0    ## roots queued for phase A
var gNePhaseBRootCount = 0    ## roots held back for phase B
var gNePhaseARootNames = ""   ## the NAMES of the phase-A roots, comma separated
var gNePhaseAVisited = 0      ## nodes phase A actually visited
var gNePhaseACandidates = 0   ## Canvas components phase A found
var gNePhaseAExhaustive = false  ## did phase A drain without truncating?
var gNePhaseAUiNamed = 0      ## phase-A roots whose name looks like UI
var gNeAnchorSceneOk = false  ## did GameObject::get_scene_Injected answer?

## PHASE 0 -- the shared `nuCanvasFind`. Kept as its own three fields so the
## ledger can never conflate "the shared finder said ABSENT" with "the shared
## finder never ran". Run at most once per discovery attempt.
var gNePhase0Done = false
var gNePhase0Verdict = "not run"
var gNePhase0Scope = "not run"
var gNePhase0Ledger = ""

proc neLooksUi(n: string): bool =
  ## Cheap, purely lexical root-name preference. It is ONLY an ORDERING
  ## hint -- a root that does not match is still searched, just later -- so
  ## a miss here can delay the answer but can never turn a present canvas
  ## into an absent one. That is deliberate: a name filter that could
  ## EXCLUDE would be a check that cannot fail.
  if n.len == 0: return false
  var u = ""
  for c in n:
    if c >= 'a' and c <= 'z': u.add char(int(c) - 32)
    else: u.add c
  u.contains("CANVAS") or u.contains("UI") or u.contains("SCREEN") or
    u.contains("HUD") or u.contains("MENU") or u.contains("GAME SCENE")

proc neSeedSkipped(i: int): bool =
  for k in 0 ..< gNeSeedSkip.len:
    if gNeSeedSkip[k] == int32(i): return true
  false

proc neSeedStepName(s: int): string =
  case s
  of NeSeedAnchor:  "anchor(splAnchor)"
  of NeSeedEnum:    "enumerate(iSceneRoots)"
  of NeSeedConvert: "convert(GameObject::get_transform)"
  of NeSeedDone:    "done"
  else:             "idle"

proc neCrumb(): string =
  ## The native breadcrumb `aowl_insp_mark` writes before EVERY internal call
  ## in the inspector's walkers -- including all six scene-root calls. It has
  ## existed the whole time; natesp simply never read it, which is why 24
  ## faults produced no name. This turns the next fault into "faulted at
  ## <step>, last internal call was <crumb> on <ptr>".
  let c = cInspCrumb()
  if c == nil: return "<none>"
  readCString(c)

proc neOk(p: Il2CppPtr; n: int32): bool =
  p != nil and cIsReadable(p, n) != 0'i32

# ---------------------------------------------------------------------------
# LIVENESS, NOT READABILITY
#
# MEASURED (integ-beta6, loaded Woods raid): discovery faulted on six
# consecutive frames and self-disabled. Readability was never the missing
# check -- a destroyed UnityEngine.Object keeps a perfectly READABLE managed
# shell with `m_CachedPtr` (+0x10) zeroed. Unity's "fake null". The nu*
# primitives in nativeui.nim guard with `nuOk`, which is readability only,
# and every one of the four this walk uses -- Component::get_gameObject,
# GameObject::get_transform, GameObject::get_activeInHierarchy and
# RectTransform::get_rect_Injected -- is an ICALL that dereferences that
# zeroed pointer inside Unity's C++, where no `aowl_p_p_seh` of ours reaches.
# In a menu those objects are rare; in a raid the tree is full of them.
#
# So natesp calls the nu* layer ONLY through these wrappers. They are local on
# purpose: nativeui is shared with other features and tightening it under them
# is a change with a blast radius this fix has no business taking.
# ---------------------------------------------------------------------------
proc neLive(p: Il2CppPtr): bool =
  ## duOk is readability; iUnityAlive reads m_CachedPtr. BOTH, in that order --
  ## a plain guarded field read that cannot itself fault.
  duOk(p, 0x20'i32) and iUnityAlive(p)

proc neGameObjectOf(component: Il2CppPtr): Il2CppPtr =
  if not neLive(component): return nil
  let go = nuGameObjectOf(component)
  if not neLive(go): return nil
  go

proc neTransformOf(go: Il2CppPtr): Il2CppPtr =
  if not neLive(go): return nil
  let tr = nuTransformOf(go)
  if not neLive(tr): return nil
  tr

proc neActiveInHier(go: Il2CppPtr): bool =
  if not neLive(go): return false
  nuActiveInHierarchy(go)

proc neF(v: float32): string = formatFloat(float64(v), ffDecimal, 1)

proc neRefuse(why: int32) =
  ## Every failure path announces itself, once, with the measured reason.
  if gNeState == NeRefused and gNeWhy == why: return
  gNeState = NeRefused
  gNeWhy = why
  gNeVerdict = NeVInconclusive
  gNeQueue = @[]
  gNeDepth = @[]
  gNeHead = 0
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
  # THE LIFECYCLE GATE. It used to be "GameWorld cached AND MainPlayer
  # readable", and that is true from the moment the FIRST BOT registers during
  # scene load -- about two minutes before the player deploys -- and stays true
  # on the post-raid results screen, so the boxes armed on the loading screen
  # and drew over the results. `rpDeployed` is the shared predicate: it adds
  # Unity LIVENESS on MainPlayer (fake null is readable), membership of the
  # live AllAlivePlayersList, and the `SessionEndUIScene` results-screen
  # signal, and it answers UNKNOWN -- which is FALSE here -- rather than
  # guessing. See raidphase.nim for what it does and does NOT prove.
  if not rpDeployed(): return NeRNoGameWorld
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
  let go = neGameObjectOf(canvas)
  if go == nil: return false
  if not neActiveInHier(go): return false
  let tr = neTransformOf(go)
  if tr == nil: return false
  # get_rect_Injected is an ICALL too; `tr` is already liveness-checked by
  # neTransformOf, so this is the one hop that does not need its own re-check.
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
  gNeDepth = @[]
  gNeHead = 0
  gNeBudget = int(cNeMaxNodes())
  gNeVisited = 0
  gNeBestArea = 0'f32
  gNeSeedCount = 0
  gNeSeedDead = 0
  gNeFakeNull = 0
  gNeCandidates = 0
  gNeRejected = 0
  gNeDeepest = 0
  gNeTruncated = 0
  gNeSeedRootsGot = 0
  gNeSeedAnchor = false
  gNeSeedFaulted = 0
  gNeSeedGoSeen = 0
  gNeSeedInFlight = -1
  gNePhase = NePhaseA
  gNePhaseBRoots = @[]
  gNePhaseARootCount = 0
  gNePhaseBRootCount = 0
  gNePhaseARootNames = ""
  gNePhaseAVisited = 0
  gNePhaseACandidates = 0
  gNePhaseAExhaustive = false
  gNePhaseAUiNamed = 0
  gNeAnchorSceneOk = false
  gNeSeedTries = gNeSeedTries + 1
  # STEP 1 -- THE ANCHOR, OBTAINED THE SAME WAY splFindScreen OBTAINS IT.
  #
  # This used to read the raw global `gSplUpdatePreloader` with no
  # readability check and no fallback. `iSceneRoots(anchor = nil)` then falls
  # through to `gInspPreloader`, which ONLY the live inspector's rider ever
  # writes -- fact #234's exact shape: with `liveInspector` off, natesp would
  # have been enumerating SceneManager's listed scenes alone, and on this build
  # those truthfully report rootCount=0 because the live UI is in
  # DontDestroyOnLoad. `splAnchor()` is the durable accessor: it prefers the
  # PreloaderUI::Update `this` captured by the shared Update rider (populated
  # with liveInspector OFF), falls back to the inspector's, and `duOk`s both.
  gNeSeedStep = NeSeedAnchor
  let anchor = splAnchor()
  gNeSeedAnchor = anchor != nil
  # STEP 2 -- ENUMERATE. `Scene::GetRootGameObjects` allocates a List and an
  # array and runs class-init on first use (abi/aowlspt_navui.h says so in as
  # many words: "never in a per-frame path"). It is ONE-TIME here -- gated by
  # `gNeSeeded` -- which is the exception that comment allows. But a seed that
  # FAULTS leaves `gNeSeeded` false and therefore repeats every frame, which is
  # exactly the per-frame allocating path the comment forbids. That is why the
  # fault budget must name this step and stop, rather than retry blindly.
  gNeSeedStep = NeSeedEnum
  # 2a -- THE ANCHOR'S OWN SCENE, ASKED FOR SEPARATELY. `iSceneRoots` folds
  # it in at the END of one flat list, which is precisely where a FIFO can
  # never reach it in a raid. Asking `iAnchorSceneHandle` directly is the
  # same two calls it would have made, and it gives us the one thing the
  # flat list destroys: WHICH roots are the DontDestroyOnLoad ones.
  var anchorRoots: seq[Il2CppPtr] = @[]
  gNeAnchorSceneOk = false
  if anchor != nil:
    var haveAh = false
    let ah = iAnchorSceneHandle(haveAh, anchor)
    gNeAnchorSceneOk = haveAh
    if haveAh:
      var bound = 0
      iRootsOfHandle(ah, "anchor", anchorRoots, false, bound)
  # 2b -- EVERYTHING SceneManager lists (this also re-includes the anchor
  # scene when SceneManager happens to list it; the dedupe below handles
  # that, and a duplicate would only ever cost a second visit, never a
  # wrong answer).
  var roots: seq[Il2CppPtr] = @[]
  discard iSceneRoots(roots, false, anchor)
  gNeSeedRootsGot = roots.len
  # STEP 3 -- QUEUE. THIS IS THE BUG THAT WAS MEASURED.
  #
  # `iSceneRoots` does NOT hand back GameObjects. `iRootsOfHandle` converts
  # each element of the `GameObject[]` to a Transform AT THE BOUNDARY, once,
  # and appends the TRANSFORM -- its own comment says so in as many words
  # ("everything downstream ... operates on Transforms, so a $rN that meant
  # something different from $c0 or $f1 would be a trap waiting for someone to
  # walk into it later"). natesp walked into it: it called `neTransformOf`,
  # i.e. `GameObject::get_transform`, with `this` = a TRANSFORM.
  #
  # That is why the ledger read 178/0/0. A Transform is a UnityEngine.Object,
  # so it is readable AND `m_CachedPtr` is a live native pointer -- it passes
  # `duOk` and it passes `iUnityAlive`, which is exactly why NOT ONE root was
  # classified dead. The type confusion only surfaces inside Unity's C++ icall,
  # where no `aowl_p_p_seh` of ours reaches. Every single root faulted.
  #
  # The array extraction was never at fault; it is the inspector's own and it
  # is the code that produces `roots` correctly every time.
  #
  # So: queue the Transform directly. The one defensive branch uses the
  # inspector's LEARNED klass blacklist -- `iIsGameObject` is populated only
  # from pointers a target returned as a GameObject by contract, never guessed
  # -- so an untranslated GameObject arriving here is converted rather than
  # silently mis-called, and it is COUNTED.
  gNeSeedStep = NeSeedConvert
  # STEP 3a -- TIER. Build ONE ordered universe so the fault-skip list keeps a
  # single stable index space, then split it at the phase-A boundary.
  var universe: seq[Il2CppPtr] = @[]
  var uIsA: seq[bool] = @[]
  var uName: seq[string] = @[]
  for g in anchorRoots:
    if universe.len >= NeMaxRootUniverse: break
    universe.add g
    uIsA.add true
    uName.add iObjName(g)
  for g in roots:
    if universe.len >= NeMaxRootUniverse: break
    var dup = false
    for k in 0 ..< universe.len:
      if universe[k] == g:
        dup = true
        break
    if dup: continue
    universe.add g
    uIsA.add false
    uName.add iObjName(g)
  # Four buckets, appended in search order. A root is never DROPPED by this,
  # only DEFERRED -- see neLooksUi.
  var ordered: seq[Il2CppPtr] = @[]
  var oIsA: seq[bool] = @[]
  var oName: seq[string] = @[]
  var pass = 0
  while pass < 4:
    let wantA = pass < 2
    let wantUi = (pass and 1) == 0
    for k in 0 ..< universe.len:
      if uIsA[k] != wantA: continue
      if neLooksUi(uName[k]) != wantUi: continue
      ordered.add universe[k]
      oIsA.add uIsA[k]
      oName.add uName[k]
    inc pass
  var idx = 0
  for g in ordered:
    let i = idx
    inc idx
    if neSeedSkipped(i):
      # Proven to fault on an earlier attempt. Skipping it is the whole point:
      # 24 faults on 178 roots killed the feature before the walk ever started.
      inc gNeSeedFaulted
      continue
    gNeSeedInFlight = i
    var tr: Il2CppPtr = nil
    if iIsGameObject(g):
      # Not the contract, but not a guess either: the klass is KNOWN to be a
      # GameObject. Convert it properly instead of calling a Transform method
      # on it.
      inc gNeSeedGoSeen
      tr = neTransformOf(g)
    elif neLive(g):
      tr = g
    if tr != nil:
      inc gNeSeedCount
      if oIsA[i]:
        # PHASE A: queued now.
        gNeQueue.add tr
        gNeDepth.add 0'i32
        inc gNePhaseARootCount
        if neLooksUi(oName[i]): inc gNePhaseAUiNamed
        if gNePhaseARootNames.len < NeMaxRootNameChars:
          if gNePhaseARootNames.len > 0: gNePhaseARootNames.add ","
          gNePhaseARootNames.add (if oName[i].len > 0: oName[i] else: "<unnamed>")
      else:
        # PHASE B: held back, entered only if A finishes empty.
        gNePhaseBRoots.add tr
        inc gNePhaseBRootCount
    else:
      inc gNeSeedDead
    gNeSeedInFlight = -1
  gNeSeedStep = NeSeedDone
  gNePhase = NePhaseA
  if gNeQueue.len == 0 and gNePhaseBRoots.len > 0:
    # No DontDestroyOnLoad root survived -- there is nothing to run phase A
    # over, so start in phase B rather than refusing. The ledger still says
    # phase A had a scope of zero, which is the honest reading.
    gNePhase = NePhaseB
    for t in gNePhaseBRoots:
      gNeQueue.add t
      gNeDepth.add 0'i32
    gNePhaseBRoots = @[]
  gNeQueue.len > 0

proc neSeedLedger(): string =
  ## THE SEED LEDGER, distinct from the walk's. Four facts, each independently
  ## falsifiable: did we get an anchor, how many roots came back, how many
  ## survived liveness, and which step we were on. `anchor=no` plus `roots=0`
  ## is a different diagnosis from `anchor=yes roots=274 live=0`, and one line
  ## that could not tell them apart is a line that cannot fail.
  "seed: tries=" & $gNeSeedTries &
  " anchor=" & (if gNeSeedAnchor: "yes" else: "NO") &
  " rootsObtained=" & $gNeSeedRootsGot &
  " liveRootsSeeded=" & $gNeSeedCount &
  " rootsSkippedDead=" & $gNeSeedDead &
  " rootsFaulted=" & $gNeSeedFaulted &
  " rootsAsGameObject=" & $gNeSeedGoSeen &
  " anchorSceneResolved=" & (if gNeAnchorSceneOk: "yes" else: "NO") &
  " phaseARoots=" & $gNePhaseARootCount &
  " phaseARootNames=\"" & gNePhaseARootNames & "\"" &
  " phaseBRoots=" & $gNePhaseBRootCount &
  " inFlightIdx=" & $gNeSeedInFlight &
  " step=" & neSeedStepName(gNeSeedStep) &
  " lastInternalCall=\"" & neCrumb() & "\" on 0x" &
  hexOf(cast[uint64](cInspCrumbPtr()))

# ---------------------------------------------------------------------------
# CREATING OUR OWN CANVAS -- the third outcome
#
# ORDERING IS FIND-THEN-CREATE, ALWAYS. This is reached only when phase 0 asked
# EVERY live root and answered ABSENT, and the breadth-first fallback then
# finished EXHAUSTIVELY over both phases with nothing. Creating a canvas while
# a usable one exists would double-draw and fight it for z-order, so the
# preconditions are checked in `neDiscoverStep`, not here, and this proc never
# runs while `gNeCanvasGo` is bound.
#
# WHY IT IS PLAUSIBLE AT ALL. Proven live 2026-08-30 (IMAGEPROOF VERDICT =
# PASS): il2cpp_object_new with a class pointer borrowed from a live GameObject
# header, GameObject::.ctor(String), then AddComponent<T> through the game's own
# .data MethodInfo slot, produced a real 240x120 Image with an auto-added
# CanvasRenderer. What that proof did NOT include was a Canvas -- Stage C never
# discovered one; it parented under a settings-menu control and Unity's OnEnable
# filled `Graphic.m_Canvas` by ANCESTOR WALK. The lesson taken here is exactly
# that: what a Graphic needs is a PARENT CHAIN ending at a Canvas, and a chain
# we built ourselves is as good as one we found.
#
# TYPES, NAMED AT EVERY HOP, because a Transform passes both readability and
# Unity liveness while being the wrong object and that cost four rounds:
#   splAnchor()          -> a PreloaderUI COMPONENT (not a GameObject)
#   neGameObjectOf(...)  -> GAMEOBJECT           (the class donor, read-only)
#   nuCreate(...)        -> GAMEOBJECT           (ours)
#   nuAdd(RectTransform) -> RECTTRANSFORM COMPONENT
#   nuAdd(Canvas)        -> CANVAS COMPONENT     (what the setters take)
#   nuTransformOf(go)    -> RECTTRANSFORM        (what boxes parent to)
#
# GUARD: no `aowl_p_p_seh` is opened here. Everything below runs inside the ONE
# guarded region `cNeTickGuarded` already established for the whole tick; an
# inner guard would DISARM it. Every hop is duOk + iUnityAlive (`neLive`) or
# nuOk-checked by the nu* primitive it calls.
#
# ALLOCATION: strictly one-time. `gNeCreateTried` makes it once per discovery
# pass, and a successful creation leaves the state machine in NeSettle/NeBuild,
# neither of which comes back here.
# ---------------------------------------------------------------------------
proc neDestroyOwnCanvas(why: string) =
  ## OWNERSHIP. Only ever destroys a canvas WE created -- `gNeOwnCanvasGo` is
  ## nil for a discovered one, so a FOUND canvas can never be taken down by
  ## this. Called on every refusal in the creation sequence, so no half-built
  ## canvas is ever left behind, and on teardown so it cannot leak into the
  ## next raid.
  if gNeOwnCanvasGo != nil:
    okLog "natesp: destroying OUR canvas 0x" &
          hexOf(cast[uint64](gNeOwnCanvasGo)) & " -- " & why
    discard nuDestroy(gNeOwnCanvasGo)
  gNeOwnCanvasGo = nil
  gNeOwnCanvasComp = nil
  gNeOwnCanvasTr = nil
  if gNeCanvasOrigin == NeOriginCreated:
    gNeCanvasGo = nil
    gNeCanvasTr = nil
    gNeCanvasW = 0'f32
    gNeCanvasH = 0'f32
    gNeCanvasOrigin = NeOriginNone

proc neCreateCanvas(): bool =
  ## Build a screen-space overlay Canvas of our own. Returns true only when
  ## every step succeeded; on ANY refusal it destroys what it made, names the
  ## reason and returns false. It does NOT decide the canvas is usable -- that
  ## is `neSettleStep`, which reads the finished state back off the live object.
  gNeCreateTried = true
  # HOP 1 -- the class donor. Read-only; we never touch it again.
  let anchor = splAnchor()                   # PreloaderUI COMPONENT
  if not neLive(anchor):
    warn "natesp: cannot create a canvas -- splAnchor() gave no live " &
         "DontDestroyOnLoad object to take a GameObject class pointer from. " &
         "Nothing was allocated."
    neRefuse(NeRCanvasDonor)
    return false
  let donorGo = neGameObjectOf(anchor)       # GAMEOBJECT
  if donorGo == nil:
    warn "natesp: cannot create a canvas -- the anchor is live but " &
         "Component::get_gameObject did not yield a live GameObject, so there " &
         "is no class pointer to borrow. Nothing was allocated."
    neRefuse(NeRCanvasDonor)
    return false
  # HOP 2 -- the GameObject. nuCreate round-trips get_name through the game, so
  # an allocation that was never constructed is refused here, not later.
  let go = nuCreate("aowlspt-esp-canvas", donorGo)   # GAMEOBJECT (ours)
  if go == nil:
    warn "natesp: canvas creation refused at step 1 of 6 (allocate + " &
         "GameObject::.ctor). Nothing survives."
    neRefuse(NeRCanvasCreate)
    return false
  gNeOwnCanvasGo = go
  # HOP 3 -- RectTransform BEFORE Canvas. Unity would add one implicitly, but
  # an implicit component is one we never judged; adding it explicitly puts it
  # through nuAdd's klass verdict like everything else.
  if nuAdd(go, NuKindRectTransform) == nil:
    neDestroyOwnCanvas("AddComponent<RectTransform> refused (step 2 of 6)")
    neRefuse(NeRCanvasCreate)
    return false
  # HOP 4 -- the Canvas COMPONENT itself. With no canvas anywhere in the raid
  # there is no live instance to register as a reference, so this comes back
  # ATTESTED rather than VERIFIED -- on the strength of the offline proof that
  # .data slot 0x6D586F8 is AddComponent<UnityEngine.Canvas>. That is why the
  # readback in neSettleStep is the gate and this is not.
  let canvas = nuAdd(go, NuKindCanvas)              # CANVAS COMPONENT
  if canvas == nil:
    neDestroyOwnCanvas("AddComponent<Canvas> refused (step 3 of 6) -- its " &
                       ".data MethodInfo slot may still be COLD in this raid")
    neRefuse(NeRCanvasCreate)
    return false
  gNeOwnCanvasComp = canvas
  # HOP 5 -- render to the screen. Not optional and not cosmetic: the default
  # for a fresh Canvas is ScreenSpaceOverlay, but relying on a default is an
  # assumption, and the two other modes both put our boxes in the world.
  if not nuCanvasSetRenderMode(canvas, NuRenderModeOverlay):
    neDestroyOwnCanvas("set_renderMode refused (step 4 of 6)")
    neRefuse(NeRCanvasCreate)
    return false
  discard nuCanvasSetSortingOrder(canvas, cNeCanvasSortOrder())
  discard nuSetLayer(go, cNeUiLayer())
  # HOP 6 -- activate. Everything above happened on an inactive object, so no
  # Unity lifecycle callback has run against a half-built canvas.
  if not nuSetActive(go, true):
    neDestroyOwnCanvas("SetActive(true) refused (step 5 of 6)")
    neRefuse(NeRCanvasCreate)
    return false
  let tr = nuTransformOf(go)                        # RECTTRANSFORM
  if tr == nil or not neLive(tr):
    neDestroyOwnCanvas("get_transform gave no live RectTransform (step 6 of 6)")
    neRefuse(NeRCanvasCreate)
    return false
  gNeOwnCanvasTr = tr
  gNeSettleFrom = gNeTicks
  gNeSettleReads = 0
  gNeSettleLast = "not read yet"
  okLog "natesp: OUR canvas was CREATED at 0x" & hexOf(cast[uint64](go)) &
        " (canvas component 0x" & hexOf(cast[uint64](canvas)) &
        ", rectTransform 0x" & hexOf(cast[uint64](tr)) &
        ", renderMode written = ScreenSpaceOverlay, sortingOrder " &
        $int(cNeCanvasSortOrder()) & ", layer " & $int(cNeUiLayer()) &
        ", active). NOTHING IS PARENTED TO IT YET: every call returning is " &
        "not a finished state, so it now has up to " &
        $int(cNeCanvasSettleTicks()) & " ticks to READ BACK as " &
        "renderMode==0 + activeInHierarchy + a rect of at least " &
        neF(cNeMinCanvasPx()) & "px on both axes, or it is destroyed."
  true

proc neSettleStep() =
  ## THE READBACK, retried. Asserts a property of the FINISHED STATE -- what
  ## the live Canvas says it is -- never of our own writes. Three outcomes:
  ## sane -> CREATED and on to the pool; cap reached -> REFUSED and the canvas
  ## is DESTROYED; anything faults -> the discovery fault ledger, as before.
  if gNeOwnCanvasGo == nil or gNeOwnCanvasComp == nil or gNeOwnCanvasTr == nil:
    neRefuse(NeRCanvasCreate)
    return
  inc gNeSettleReads
  if not neLive(gNeOwnCanvasGo) or not neLive(gNeOwnCanvasComp) or
     not neLive(gNeOwnCanvasTr):
    neDestroyOwnCanvas("it stopped being Unity-alive while settling " &
                       "(a scene change is the usual reason)")
    neRefuse(NeRCanvasUnverified)
    return
  let mode = nuCanvasRenderMode(gNeOwnCanvasComp)
  let act = neActiveInHier(gNeOwnCanvasGo)
  let (okR, _, _, rw, rh) = nuGetRect(gNeOwnCanvasTr)
  gNeSettleLast = "renderMode=" & $int(mode) & " activeInHierarchy=" &
                  (if act: "yes" else: "NO") & " rectRead=" &
                  (if okR: "yes" else: "NO") & " rect=" & neF(rw) & "x" & neF(rh)
  if mode == NuRenderModeOverlay and act and okR and
     rw >= cNeMinCanvasPx() and rh >= cNeMinCanvasPx():
    gNeCanvasGo = gNeOwnCanvasGo
    gNeCanvasTr = gNeOwnCanvasTr
    gNeCanvasW = rw
    gNeCanvasH = rh
    gNeCanvasOrigin = NeOriginCreated
    gNeBestArea = rw * rh
    okLog "natesp: canvas CREATED and VERIFIED after " & $gNeSettleReads &
          " readback(s) over " & $int(gNeTicks - gNeSettleFrom) & " tick(s) -- " &
          gNeSettleLast & ". This is the live object's own answer, not a " &
          "record of what we wrote. Building the pool under it."
    gNeState = NeBuild
    return
  if (gNeTicks - gNeSettleFrom) >= int64(cNeCanvasSettleTicks()):
    warn "natesp: our canvas NEVER read back sane within " &
         $int(cNeCanvasSettleTicks()) & " ticks (" & $gNeSettleReads &
         " readbacks; last: " & gNeSettleLast & "; required renderMode=0 + " &
         "activeInHierarchy + rect >= " & neF(cNeMinCanvasPx()) &
         "px on both axes). A timeout here is a REFUSAL, never a pass."
    neDestroyOwnCanvas("it never read back sane")
    neRefuse(NeRCanvasUnverified)

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

  # ------------------------------------------------------------------ PHASE 0
  # THE SHARED FINDER, TRIED FIRST. `nuCanvasFind` (nuikit.nim) is the host's
  # ONE canvas-acquisition function; the breadth-first walk below is now a
  # fallback behind it, not a second implementation.
  #
  # WHY IT IS EXPECTED TO WIN WHERE THE WALK LOST. MEASURED, 2026-08-30: the
  # walk reported `visited=20000 candidates=0 deepest=3/8 scope=TRUNCATED` --
  # it burned the entire node budget on map geometry three levels down and
  # never reached any UI at all. A Canvas sits AT or very near a scene root,
  # so asking each root directly for a `Canvas` component is ~16 questions
  # rather than 20,000 and cannot truncate before reaching the UI.
  #
  # ACCEPTANCE IS UNCHANGED and now lives in the shared function: alive +
  # activeInHierarchy + rect READS BACK >= `aowl_ne_min_canvas_px` on both
  # axes, largest area wins, nothing is created if none qualifies.
  #
  # GUARD: `nuCanvasFind` opens NO `aowl_p_p_seh` of its own (nuikit opens none
  # anywhere, by design), so calling it from inside this tick body's single
  # guarded region does NOT nest and does NOT disarm the outer guard.
  #
  # 9b: its verdict is three-state and is logged verbatim. `ABSENT` means the
  # roots were examined and none qualified; `INCONCLUSIVE` means we never got
  # to look. Only INCONCLUSIVE falls through to the walk -- an ABSENT verdict
  # from the roots still falls through too, because the walk can reach nested
  # canvases the root ask cannot, but the ledger says which happened.
  if gNeCanvasTr == nil and not gNePhase0Done:
    gNePhase0Done = true
    var pick = NuCanvasPick()
    let got = nuCanvasFind(splAnchor(), cNeMinCanvasPx(), pick)
    gNePhase0Verdict = pick.verdict
    gNePhase0Scope = pick.scope
    gNePhase0Ledger = nuCanvasLedger(pick)
    okLog "natesp: phase0 (shared nuCanvasFind, the host's ONE canvas " &
          "acquisition) -- " & gNePhase0Ledger
    if got and pick.go != nil and pick.tr != nil:
      gNeCanvasGo = pick.go
      gNeCanvasTr = pick.tr
      gNeCanvasOrigin = NeOriginFound   # FIND-THEN-CREATE: never create over one
      gNeCanvasW = pick.w
      gNeCanvasH = pick.h
      gNeBestArea = pick.w * pick.h
      gNeCandidates = pick.candidates
      gNeRejected = pick.rejected
      okLog "natesp: canvas ACCEPTED by phase0 at 0x" &
            hexOf(cast[uint64](gNeCanvasGo)) & " name=\"" &
            iObjName(gNeCanvasGo) & "\" rect=" & neF(gNeCanvasW) & "x" &
            neF(gNeCanvasH) & " -- alive, activeInHierarchy, and the LARGEST " &
            "of " & $pick.candidates & " candidate(s) at or above " &
            neF(cNeMinCanvasPx()) & "px on both axes. The breadth-first walk " &
            "was not needed and did not run."
      gNeSeeded = true            # the walk is skipped, not merely finished
      gNeHead = 0
      gNeQueue = @[]
      return
    okLog "natesp: phase0 did not bind a canvas (verdict=" & gNePhase0Verdict &
          "). Falling through to the breadth-first walk, which can reach " &
          "canvases NESTED below a root that the root-level ask cannot see. " &
          "If the walk also finds nothing, read the two verdicts TOGETHER: " &
          "phase0=ABSENT plus a walk that ran EXHAUSTIVELY is a real absence; " &
          "either one reading INCONCLUSIVE or TRUNCATED is not."

  if not gNeSeeded:
    # THE ATTEMPT CAP, checked BEFORE the enumeration, not after.
    # `Scene::GetRootGameObjects` allocates; a seed that can never succeed must
    # not keep allocating once per frame forever. MEASURED: it did exactly that
    # 24 times before the discovery fault ledger happened to cap out.
    if gNeSeedTries >= int(cNeMaxSeedTries()):
      if not gNeSeedGiven:
        gNeSeedGiven = true
        warn "natesp: giving up on SEEDING after " & $gNeSeedTries &
             " attempts -- " & neSeedLedger() & ". Scene::GetRootGameObjects " &
             "ALLOCATES, so retrying it every frame is itself a defect. This " &
             "is INCONCLUSIVE, not proof there is no canvas."
      neRefuse(NeRSeedTries)
      return
    if not neSeed():
      # NOT a bare "no roots". Say which of the two distinguishable causes it
      # was, and say plainly when the anchor is the missing piece -- natesp
      # must never depend on `liveInspector` being on, so if that is what is
      # missing it is named here rather than silently producing zero roots.
      warn "natesp: SEEDING produced no usable scene root -- " & neSeedLedger() &
           ". " &
           (if not gNeSeedAnchor:
              "NO durable DontDestroyOnLoad anchor was available " &
              "(gSplUpdatePreloader and gInspPreloader are both null/unreadable), " &
              "so only the scenes SceneManager LISTS could be enumerated -- and on " &
              "this build those truthfully report rootCount=0 because the live UI " &
              "is in DontDestroyOnLoad. This is INCONCLUSIVE, not proof there is " &
              "no canvas. It resolves once a PreloaderUI::Update rider slot has " &
              "been claimed; it does NOT require liveInspector."
            elif gNeSeedRootsGot == 0:
              "An anchor WAS obtained and iSceneRoots still returned nothing: " &
              "the scene enumeration itself came back empty. INCONCLUSIVE."
            else:
              "An anchor was obtained and " & $gNeSeedRootsGot & " root(s) came " &
              "back, but none was queued: " & $gNeSeedDead & " failed the " &
              "liveness check and " & $gNeSeedFaulted & " FAULTED and were " &
              "skipped. Those two are deliberately separate -- when they were " &
              "one field, 178 roots reported 0 seeded and 0 dead and the " &
              "ledger could not say which had happened. INCONCLUSIVE.")
      neRefuse(NeRNoRoots)
      return
    gNeSeeded = true
    okLog "natesp: " & neSeedLedger()
    okLog "natesp: canvas discovery started -- " & $gNeSeedCount &
          " live scene roots seeded (DontDestroyOnLoad included via the live " &
          "anchor), " & $gNeSeedDead & " root(s) skipped as fake nulls, " &
          "budget " & $gNeBudget & " nodes, depth cap " & $int(cNeMaxDepth()) &
          ", " & $int(cNeSliceMs()) &
          "ms per frame. Nothing is parented until a canvas PASSES."
  let started = cNowMs()
  var spent = 0
  while gNeHead < gNeQueue.len:
    if gNeBudget <= 0: break
    if (spent and 31) == 0 and cNowMs() - started > uint64(cNeSliceMs()):
      return                      # more next frame; state unchanged
    let cur = gNeQueue[gNeHead]
    let depth = int(gNeDepth[gNeHead])
    inc gNeHead
    inc spent
    dec gNeBudget
    # A fake null is a NORMAL outcome of walking a live raid scene, not a
    # failure: it is counted and skipped. Charging it to the fault budget is
    # what disabled the feature after six of them.
    if not neLive(cur):
      inc gNeFakeNull
      continue
    inc gNeVisited
    if depth > gNeDeepest: gNeDeepest = depth
    let canvas = neGetComponent(fnGet, cur, gNeTypeCanvas)
    if canvas != nil:
      inc gNeCandidates
      var cw = 0'f32
      var ch = 0'f32
      if neCanvasRect(canvas, cw, ch):
        let area = cw * ch
        if area > gNeBestArea:
          # Bind the winner only through the liveness-checked hops; the raw
          # nu* pair here could hand back a fake null we would then parent to.
          let go = neGameObjectOf(canvas)
          let tr = neTransformOf(go)
          if go != nil and tr != nil:
            gNeBestArea = area
            gNeCanvasGo = go
            gNeCanvasTr = tr
            gNeCanvasOrigin = NeOriginFound
            gNeCanvasW = cw
            gNeCanvasH = ch
          else:
            inc gNeRejected
      else:
        inc gNeRejected
    if gNeGraphicDonor == nil:
      let img = neGetComponent(fnGet, cur, gNeTypeImage)
      if img != nil: gNeGraphicDonor = img
    var n = 0
    if iChildCount(cur, n):
      if depth + 1 > int(cNeMaxDepth()):
        # Not a silent truncation: counted, and named in the refusal line.
        gNeTruncated = gNeTruncated + n
      else:
        var k = 0
        while k < n and k < int(cNeMaxChildren()):
          # The node budget bounds POPS, not pushes. Without this the queue
          # grows without bound in a raid -- millions of pointers of native
          # memory for nodes that can never be reached before the budget runs
          # out. Cap it at twice the budget and COUNT what was dropped.
          if gNeQueue.len >= int(cNeMaxNodes()) * 2:
            gNeTruncated = gNeTruncated + (n - k)
            break
          let c = iChildAt(cur, k)
          if c != nil:
            gNeQueue.add c
            gNeDepth.add int32(depth + 1)
          inc k
  # The walk is FINISHED (queue drained or budget spent). Decide, out loud.
  #
  # THE DISCOVERY LEDGER. Every number here is a count of something that
  # actually happened, and the two ways the search could have been INCOMPLETE
  # -- budget exhausted, depth cap hit -- are stated separately from the
  # verdict, so "no canvas" is never confused with "I could not look".
  let exhaustive = gNeHead >= gNeQueue.len and gNeBudget > 0 and gNeTruncated == 0
  # PHASE A FINISHED WITHOUT A WINNER -> FALL THROUGH TO PHASE B.
  #
  # Phase A's numbers are FROZEN here, before phase B overwrites the shared
  # counters, because they are the ones that answer the question that
  # `candidates=0` alone could not: did we search where the UI lives, and
  # did we finish? A phase-A line reading `phaseA scope=EXHAUSTIVE
  # roots="Common UI,Menu UI,Canvas,..." candidates=0` is a real absence in
  # DontDestroyOnLoad. A phase-A line reading `roots=0` or
  # `scope=TRUNCATED` is "I never got there", and says so.
  if (gNeCanvasTr == nil or gNeCanvasGo == nil) and gNePhase == NePhaseA:
    gNePhaseAVisited = gNeVisited
    gNePhaseACandidates = gNeCandidates
    gNePhaseAExhaustive = exhaustive
    okLog "natesp: PHASE A (DontDestroyOnLoad, " & $gNePhaseARootCount &
          " root(s), " & $gNePhaseAUiNamed & " UI-named, searched first) " &
          "found no qualifying Canvas. roots=\"" & gNePhaseARootNames &
          "\" visited=" & $gNePhaseAVisited & " candidates=" &
          $gNePhaseACandidates & " deepest=" & $gNeDeepest & "/" &
          $int(cNeMaxDepth()) & " budgetLeft=" & $gNeBudget & " scope=" &
          (if exhaustive: "EXHAUSTIVE" else: "TRUNCATED") &
          ". Falling through to PHASE B (" & $gNePhaseBRootCount &
          " remaining scene root(s), fresh budget)."
    if gNePhaseBRoots.len > 0:
      gNePhase = NePhaseB
      gNeQueue = @[]
      gNeDepth = @[]
      gNeHead = 0
      gNeBudget = int(cNeMaxNodes())
      gNeTruncated = 0
      for t in gNePhaseBRoots:
        gNeQueue.add t
        gNeDepth.add 0'i32
      gNePhaseBRoots = @[]
      return                       # phase B starts on the next frame's slice
  let phaseLedger =
    " phase0=" & gNePhase0Verdict &
    " phase0Ledger=\"" & gNePhase0Ledger & "\"" &
    " phaseA=" & (if gNePhaseARootCount == 0: "NOT-SEARCHED(0 roots)"
                  else: (if gNePhaseAExhaustive: "EXHAUSTIVE" else: "TRUNCATED")) &
    " phaseARoots=" & $gNePhaseARootCount &
    " phaseAUiNamed=" & $gNePhaseAUiNamed &
    " phaseAVisited=" & $gNePhaseAVisited &
    " phaseACandidates=" & $gNePhaseACandidates &
    " phaseARootNames=\"" & gNePhaseARootNames & "\"" &
    " phaseBRoots=" & $gNePhaseBRootCount &
    " anchorSceneResolved=" & (if gNeAnchorSceneOk: "yes" else: "NO") &
    " phaseNow=" & (if gNePhase == NePhaseA: "A" else: "B")
  let ledger = phaseLedger & " visited=" & $gNeVisited & " fakeNullsSkipped=" & $gNeFakeNull &
               " canvasCandidates=" & $gNeCandidates & " rejected=" &
               $gNeRejected & " deepest=" & $gNeDeepest & "/" &
               $int(cNeMaxDepth()) & " budgetLeft=" & $gNeBudget &
               " queued=" & $gNeQueue.len & " childrenDropped=" & $gNeTruncated &
               " discFaults=" & $gNeDiscFaults & " scope=" &
               (if exhaustive: "EXHAUSTIVE" else: "TRUNCATED")
  if gNeCanvasTr == nil or gNeCanvasGo == nil:
    okLog "natesp: discovery walk FINISHED with no qualifying Canvas. " &
          ledger & ". A canvas qualifies only if it is alive, " &
          "activeInHierarchy and its rect READS BACK at least " &
          neF(cNeMinCanvasPx()) & "px on both axes. " &
          (if gNePhaseARootCount == 0:
             "PHASE A WAS NEVER SEARCHED: zero DontDestroyOnLoad roots were " &
             "queued (anchorSceneResolved=" &
             (if gNeAnchorSceneOk: "yes" else: "NO") & "), and the live UI on " &
             "this build lives ONLY in DontDestroyOnLoad. This is " &
             "INCONCLUSIVE -- we did not look where the canvas is."
           elif not gNePhaseAExhaustive:
             "PHASE A itself was TRUNCATED (budget or depth cap) over its " &
             $gNePhaseARootCount & " DontDestroyOnLoad root(s), so the place " &
             "the canvas actually lives was not fully searched. INCONCLUSIVE."
           elif exhaustive:
             "PHASE A was EXHAUSTIVE over the DontDestroyOnLoad roots named " &
             "above and phase B was exhaustive too, so this is a real " &
             "absence, not a truncation."
           else:
             "PHASE A was EXHAUSTIVE over the DontDestroyOnLoad roots named " &
             "above -- so no canvas is present WHERE THE UI LIVES -- but " &
             "phase B was TRUNCATED, so the remaining scenes are " &
             "INCONCLUSIVE.")
    # ------------------------------------------------------- CREATE OUR OWN
    # THE GATE IS PHASE 0 ALONE, and that is a deliberate narrowing.
    #
    # It used to require THREE answers: phase0 ABSENT/EXHAUSTIVE, phase A
    # exhaustive, and this walk exhaustive. MEASURED 2026-08-31, live raid:
    # phase 0 said `rootsSeen=178 walked=178 asked=178 dead=0 unaskable=0
    # askCap=512 scope=EXHAUSTIVE` -> ABSENT, a real, exhaustively-established
    # absence at ROOT level -- and then the walk reported `visited=20000
    # budgetLeft=0 queued=32879 deepest=3/8 scope=TRUNCATED` and the gate
    # refused. The walk cannot establish nested absence at ANY sane budget, so
    # requiring it made the gate UNSATISFIABLE: a condition that can never be
    # true is not a safety check, it is a permanent refusal wearing one.
    #
    # And the requirement was self-imposed. We do not need the GAME's canvas --
    # we need A canvas. `neCreateCanvas` allocates one we OWN (`gNeOwnCanvasGo`
    # is set only for ours) and `neDestroyOwnCanvas` takes it down at raid end.
    # The double-draw hazard the old comment named is a hazard of parenting to
    # someone else's canvas twice, not of owning our own overlay.
    #
    # The nested walk is KEPT, but only as a PREFERENCE: if it finds a
    # qualifying canvas it binds it above (origin=FOUND) and we never get here.
    # Reaching here means it did not, and a TRUNCATED walk NO LONGER BLOCKS
    # CREATION -- it is simply reported.
    let realAbsence = gNePhase0Verdict == "ABSENT" and
                      gNePhase0Scope == "EXHAUSTIVE"
    if realAbsence and not gNeCreateTried and gNeOwnCanvasGo == nil:
      okLog "natesp: CREATING OUR OWN canvas -- phase0=" & gNePhase0Verdict &
            "/" & gNePhase0Scope & " asked every live root and none carries a " &
            "Canvas, which is a REAL absence at root level. The nested walk " &
            "was a preference only and found none (walkExhaustive=" &
            (if exhaustive: "yes" else: "NO") & ", phaseARoots=" &
            $gNePhaseARootCount & ", phaseAExhaustive=" &
            (if gNePhaseAExhaustive: "yes" else: "NO") &
            "); it does NOT gate creation, because it cannot establish nested " &
            "absence at any sane budget and requiring it made the gate " &
            "unsatisfiable. We create, own and destroy this canvas ourselves."
      if neCreateCanvas():
        gNeQueue = @[]
        gNeDepth = @[]
        gNeHead = 0
        gNeState = NeSettle
      return
    if not realAbsence and not gNeCreateTried:
      okLog "natesp: NOT creating a canvas -- the ROOT-LEVEL absence is not " &
            "established. phase0=" & gNePhase0Verdict & "/" & gNePhase0Scope &
            ". Only phase 0 gates creation now; it must read ABSENT with " &
            "scope EXHAUSTIVE, meaning every live root was actually asked. " &
            "Anything else is INCONCLUSIVE -- we did not look -- and " &
            "INCONCLUSIVE is never a licence to create."
    neRefuse(NeRNoCanvas)
    return
  if gNeGraphicDonor == nil:
    okLog "natesp: a canvas qualified but no Graphic donor was found. " & ledger
    neRefuse(NeRNoGraphic)
    return
  okLog "natesp: canvas ACCEPTED at 0x" & hexOf(cast[uint64](gNeCanvasGo)) &
        " name=\"" & iObjName(gNeCanvasGo) & "\" -- it won because its rect " &
        "reads back " & neF(gNeCanvasW) & "x" & neF(gNeCanvasH) & ", the " &
        "LARGEST of " & $gNeCandidates & " Canvas candidate(s) that passed " &
        "alive+activeInHierarchy+>=" & neF(cNeMinCanvasPx()) & "px. " &
        ledger & ". Graphic donor 0x" & hexOf(cast[uint64](gNeGraphicDonor)) & "."
  # The walk is over: release the queue rather than hold megabytes of raid
  # scene pointers for the rest of the session.
  gNeQueue = @[]
  gNeDepth = @[]
  gNeHead = 0
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
  if gNeGraphicDonor == nil and gNeCanvasOrigin == NeOriginCreated:
    # THE ONE CASE WITH NOTHING TO COMPARE AGAINST. We only get here because
    # the raid provably contains no Canvas -- and a raid with no Canvas very
    # plausibly contains no UI.Image either, so there is no live instance to
    # register. `nuAdd` will therefore answer ATTESTED rather than VERIFIED,
    # on the offline token proof that slot 0x6D50070 is AddComponent<UI.Image>.
    # Said out loud, because a weaker check must never pass silently; the
    # finished-state readback in `neVerdict` remains the real gate.
    warn "natesp: no live UI.Image donor exists in this raid, so the box " &
         "component's class cannot be checked against one. Proceeding on the " &
         "OFFLINE attestation of the AddComponent<UI.Image> slot alone -- " &
         "this is ATTESTED, not VERIFIED, and only the on-screen readback " &
         "settles it."
  elif not nuRegisterReference(NuKindImage, gNeGraphicDonor):
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

  # ------------------------------------------- THE FALSIFIABLE NEGATIVE (9b)
  # NOT "we called SetParent and it returned true" -- that is a record of our
  # own write and cannot fail. This READS THE FINISHED TREE BACK through
  # Transform::get_parent and asserts a NEGATIVE that CAN come out false:
  #
  #   no ESP element is parented to anything other than the canvas we bound.
  #
  # Every box's parent must read back as the esp-root transform, and the
  # esp-root's parent must read back as the canvas transform. A single stray
  # -- a box that ended up on the game's canvas, or on nothing -- makes this
  # FAIL and the pool is refused rather than half-drawn somewhere unowned.
  # Capped by NeMaxPool, which is a compile-time constant.
  var strays = 0
  var unreadable = 0
  let rootParent = iVisParentOf(gNeRootTr)
  if rootParent == nil: inc unreadable
  elif rootParent != gNeCanvasTr: inc strays
  i = 0
  while i < NeMaxPool:
    if gNeBoxRt[i] != nil:
      let p = iVisParentOf(gNeBoxRt[i])
      if p == nil: inc unreadable
      elif p != gNeRootTr: inc strays
    inc i
  gNeParentLine = "PARENT READBACK (Transform::get_parent over the finished " &
                  "tree, not our own SetParent calls): strays=" & $strays &
                  " unreadable=" & $unreadable & " of " & $(gNeBuilt + 1) &
                  " element(s) -- the assertion is the NEGATIVE \"no ESP " &
                  "element is parented to anything other than the canvas we " &
                  "own\"; strays>0 falsifies it."
  if strays > 0:
    warn "natesp: " & gNeParentLine & " REFUSING the pool: " & $strays &
         " element(s) read back parented somewhere we do not own, which would " &
         "draw into a tree we cannot tear down at raid end."
    return false
  if unreadable > 0:
    warn "natesp: " & gNeParentLine & " This is INCONCLUSIVE, not a pass -- " &
         $unreadable & " element(s) could not be asked for their parent. The " &
         "pool is built, but do not read the PASS verdict as proof of " &
         "ownership for those."
  else:
    okLog "natesp: " & gNeParentLine
  true

# ---------------------------------------------------------------------------
# THE CENSUS -- into fixed arrays, throttled, capped
# ---------------------------------------------------------------------------
proc cRoleIsBossTier(role: int32): int32 {.
  importc: "aowl_role_is_boss_tier", nodecl.}
  ## THE ONE numeric WildSpawnType table, `abi/aowlspt_wildspawn.h`, shared
  ## verbatim with mods/maps. Pure integer classification -- it dereferences
  ## nothing, so sharing it across two binaries with different safety envelopes
  ## costs nothing.

# ---------------------------------------------------------------------------
# TWO TAXONOMIES, AND THE CONVERSION BETWEEN THEM IS WRITTEN OUT
# ---------------------------------------------------------------------------
# The ESP DRAWS four factions, because the colour palette in C
# (`aowl_ne_faction_rgba`) has four entries and the box pool is laid out as
# four contiguous per-faction runs. The maps mod CLASSIFIES five, because it
# needs Local (you) and Unknown (the walk declined) to be first-class outcomes.
#
# These are NOT interchangeable and the previous code effectively pretended
# they were. So both are computed, from ONE walk, and the fold from five to
# four is a single explicit `case` below rather than an accident of ordering:
#
#   class (5)                     draw faction (4)
#   ---------                     ----------------
#   NeClsLocal   you              -- never drawn; the census skips you
#   NeClsPmc     Usec/Bear side   NeFacUsec / NeFacBear, keeping the split
#   NeClsScav    Savage, no boss  NeFacScav
#   NeClsBoss    boss tier        NeFacBoss
#   NeClsUnknown walk declined    NeFacScav, and SAID SO in the histogram
#
# The Unknown -> Scav fold is the one lossy step and it is deliberate: there is
# no fifth colour to draw and hiding the contact would be worse than painting
# it. It is only acceptable BECAUSE the histogram counts Unknown separately, so
# a dead Profile walk shows up as `unknown=N` rather than as a convincing field
# of scavs (CLAUDE.md 9b -- the count is the thing that can falsify this).
const
  NeClsLocal   = 0'i32
  NeClsPmc     = 1'i32
  NeClsScav    = 2'i32
  NeClsBoss    = 3'i32
  NeClsUnknown = 4'i32
  NeClsCount   = 5

const
  NeFacUsec = 0'i32
  NeFacBear = 1'i32
  NeFacScav = 2'i32
  NeFacBoss = 3'i32

var gNeClsHist: array[NeClsCount, int32]
  ## THIS pass's distribution. Reset by `neScan`, read by the diagnostic.
var gNeClsEver: array[NeClsCount, int64]
  ## Cumulative for the session, so a diag opened after the interesting moment
  ## still has the numbers.

proc neClassify(pl: Il2CppPtr; cls, faction: var int32) =
  ## ONE guarded walk (`bdReadSideRole`: Player+0x9C0 -> Profile+0x48 ->
  ## ProfileInfo, +0x48 side / +0x78 Settings +0x10 role, sentinel -1 on any
  ## unreadable hop), producing BOTH taxonomies.
  ##
  ## THE FIX (fact #325, measured). This used to match the faction against a
  ## case-insensitive SUBSTRING of the role NAME -- "boss"/"raider"/"rogue"/
  ## "follower" -- which assigns a faction by SPELLING and therefore got two
  ## whole populations wrong, silently:
  ##
  ##   exUsec (24) ARE the Rogues. No "rogue" in the name, and it was reached
  ##     only after the side check had already claimed it, so a Rogue drew in
  ##     the USEC colour.
  ##   pmcBot (9) ARE the Raiders. No "raider" in the name, so a Raider fell
  ##     through to the plain-scav bucket.
  ##
  ## Two ordering points are load-bearing, not stylistic:
  ##
  ##   1. THE ROLE IS TESTED BEFORE THE SIDE. Rogues carry a PMC-looking side;
  ##      testing the side first is exactly what hid them. Boss tier outranks
  ##      side, as it does in mods/maps.
  ##   2. role == -1 is the SENTINEL for "could not read", not a role. It must
  ##      not reach the table, and a contact whose side is also unreadable is
  ##      Unknown -- never folded into Scav at the classification stage.
  var side = -1'i32
  var role = -1'i32
  bdReadSideRole(pl, side, role)

  if role >= 0'i32 and cRoleIsBossTier(role) != 0'i32:
    cls = NeClsBoss
    faction = NeFacBoss
    return
  case int(side)
  of 1:
    cls = NeClsPmc
    faction = NeFacUsec
  of 2:
    cls = NeClsPmc
    faction = NeFacBear
  of 4:
    cls = NeClsScav
    faction = NeFacScav
  else:
    cls = NeClsUnknown
    faction = NeFacScav          # the lossy fold, documented above

proc neFactionOf(pl: Il2CppPtr): int32 =
  ## Kept as the draw-side entry point; the classification lives in
  ## `neClassify` so the histogram and the colour can never disagree.
  var cls = NeClsUnknown
  var faction = NeFacScav
  neClassify(pl, cls, faction)
  faction

proc neClsName(c: int): string =
  case c
  of 0: "local"
  of 1: "pmc"
  of 2: "scav"
  of 3: "boss"
  else: "unknown"

proc neClsHistText(): string =
  ## `contacts by class: local=N pmc=N scav=N boss=N unknown=N` -- the raw
  ## distribution, never a verdict. The verdict is `neClsVerdict` and prints
  ## beside it so a reader who disagrees can check it against these counts.
  result = "contacts by class:"
  var i = 0
  while i < NeClsCount:
    result = result & " " & neClsName(i) & "=" & $gNeClsHist[i]
    inc i

proc neClsVerdict(): string =
  ## THREE OUTCOMES, never two (CLAUDE.md 9b). The falsifiable negative is
  ## "the distribution is NOT DEGENERATE": a classifier reading garbage looks
  ## exactly like every contact landing in one bucket, so one bucket holding
  ## everything is INCONCLUSIVE, not a pass. So is an empty census -- "I could
  ## not look" has never been a PASS.
  var total = 0'i32
  var nonEmpty = 0
  var i = 0
  while i < NeClsCount:
    total = total + gNeClsHist[i]
    if gNeClsHist[i] > 0'i32: inc nonEmpty
    inc i
  if total == 0'i32:
    return "INCONCLUSIVE (no contacts classified this pass -- not a pass, " &
           "there was nothing to look at)"
  if gNeClsHist[int(NeClsUnknown)] == total:
    return "FAIL (every contact is unknown -- the Profile walk is declining, " &
           "which is what a broken read looks like, not a raid full of " &
           "unclassifiable people)"
  if nonEmpty <= 1:
    return "INCONCLUSIVE (degenerate: all " & $total & " contacts in one " &
           "class. Indistinguishable from a read that returns a constant)"
  "PASS (distribution spans " & $nonEmpty & " classes over " & $total &
    " contacts -- not degenerate)"

proc neScan() =
  ## `GameWorld.RegisteredPlayers` +0x1D0, capped at NeMaxContacts, every hop
  ## guarded, read-only. Fills FIXED arrays -- botdiag's discipline with the
  ## logging and the seq allocation both removed.
  gNeCn = 0
  var h = 0
  while h < NeClsCount:
    gNeClsHist[h] = 0'i32
    inc h
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
    if bdIsYou(pl):
      # COUNTED, then skipped. The ESP deliberately does not draw a box on you,
      # but omitting you from the histogram would make `local=0` permanent and
      # therefore meaningless -- a bucket that can never be non-zero is a check
      # that cannot fail. `local` here means "the census reached you", which is
      # itself worth seeing go wrong.
      gNeClsHist[int(NeClsLocal)] = gNeClsHist[int(NeClsLocal)] + 1'i32
      gNeClsEver[int(NeClsLocal)] = gNeClsEver[int(NeClsLocal)] + 1'i64
      continue
    var posOk = false
    var x = 0.0
    var y = 0.0
    var z = 0.0
    duPlayerPos(pl, posOk, x, y, z)
    if not posOk: continue
    gNeCx[gNeCn] = x
    gNeCy[gNeCn] = y
    gNeCz[gNeCn] = z
    var cls = NeClsUnknown
    var faction = NeFacScav
    neClassify(pl, cls, faction)
    gNeCf[gNeCn] = faction
    gNeClsHist[int(cls)] = gNeClsHist[int(cls)] + 1'i32
    gNeClsEver[int(cls)] = gNeClsEver[int(cls)] + 1'i64
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

proc neCanvasLine(): string =
  ## WHICH OF THE THREE HAPPENED, in one clause, always present in the verdict.
  ## FOUND / CREATED / REFUSED(named reason) -- and for CREATED the numbers are
  ## the ones READ BACK off the live object in `neSettleStep`, not the ones we
  ## wrote.
  case int(gNeCanvasOrigin)
  of 1:
    "canvas FOUND(existing) at 0x" & hexOf(cast[uint64](gNeCanvasGo)) &
      " rect=" & neF(gNeCanvasW) & "x" & neF(gNeCanvasH) &
      " -- the game's own, discovered and left in its ownership"
  of 2:
    "canvas CREATED(ours) at 0x" & hexOf(cast[uint64](gNeCanvasGo)) &
      " rect=" & neF(gNeCanvasW) & "x" & neF(gNeCanvasH) &
      " sortingOrder=" & $int(cNeCanvasSortOrder()) &
      " -- built by us because phase0 asked EVERY live root and answered " &
      "ABSENT/EXHAUSTIVE. That root-level absence is the WHOLE gate; the " &
      "nested walk is a preference and its scope did not enter into it. " &
      "Verified by readback off the live object (renderMode via " &
      "Canvas::get_renderMode, not remembered from the set): " & gNeSettleLast &
      ". " & gNeParentLine & " It is destroyed when the raid ends."
  else:
    "canvas REFUSED -- " & readCString(cNeRefusalText(gNeWhy)) &
      (if gNeCreateTried:
         "  (creating our own WAS attempted; last canvas readback: " &
         gNeSettleLast & ")"
       else:
         "  (creating our own was NOT attempted -- phase0=" & gNePhase0Verdict &
         "/" & gNePhase0Scope & ", so the ROOT-LEVEL absence is not " &
         "established. Phase 0 is the only gate; the nested walk's scope is " &
         "not part of this decision)")

proc neVerdictBody(sw, sh: float64): string =
  case int(gNeVerdict)
  of 2:
    "natesp VERDICT PASS -- " & neCanvasLine() & ". Pool built, and " &
      $gNeOnScreen &
      " box(es) read BACK from the game as activeInHierarchy with a " &
      "renderable on-screen rect this frame (of " & $gNeShown &
      " placed, " & $gNeCn & " contact(s), " & $gNeDropped &
      " over the per-faction pool). This is the finished state, not a record " &
      "of our own writes -- but it is still not proof a human can SEE them. " &
      "`activeInHierarchy` is TRANSITIVE, so a box reading back active is also " &
      "a readback of the whole parent chain box -> aowlspt-esp-root -> " &
      neOriginName(gNeCanvasOrigin) & " canvas being active."
  of 1:
    "natesp VERDICT FAIL -- " & neCanvasLine() &
      ". Contacts exist but ZERO boxes read back active " &
      "with a valid on-screen rect. contacts=" & $gNeCn & " placed=" &
      $gNeShown & " built=" & $gNeBuilt & " canvas=" & neF(gNeCanvasW) & "x" &
      neF(gNeCanvasH) & " screen=" & duFmt0(sw) & "x" & duFmt0(sh) &
      ". The pool exists and the placement ran; the finished state is empty."
  else:
    "natesp VERDICT INCONCLUSIVE -- " & neCanvasLine() & ". " &
      readCString(cNeRefusalText(gNeWhy)) &
      "  (origin=" & neOriginName(gNeCanvasOrigin) &
      " state=" & $gNeState & " built=" & $gNeBuilt & " contacts=" & $gNeCn &
      " faults=" & $int(cNeFaultCount()) & "). discovery: visited=" &
      $gNeVisited & " fakeNullsSkipped=" & $gNeFakeNull & " candidates=" &
      $gNeCandidates & " rejected=" & $gNeRejected & " deepest=" & $gNeDeepest &
      "/" & $int(cNeMaxDepth()) & " budgetLeft=" & $gNeBudget & " head=" &
      $gNeHead & "/" & $gNeQueue.len & " discFaults=" & $gNeDiscFaults &
      ". " & neSeedLedger() & ". " &
      # `visited=0` WITH THE BUDGET UNTOUCHED IS A SEEDING FAILURE, and the
      # line must say so itself rather than leaving the reader to notice.
      # This exact combination was reported once as "the canvas walk itself
      # faulted", which sent the investigation to the walk for a fault that
      # happened before the queue existed.
      (if not gNeSeeded and gNeVisited == 0 and gNeHead == 0:
         "NOTE: the breadth-first WALK NEVER RAN -- nothing was queued, no " &
         "budget was spent, no node was visited. Whatever went wrong is in " &
         "SEEDING (see the `seed:` fields above), not in the walk."
       else: "") &
      " I could not look; that is NOT a pass."

proc neVerdictLine(sw, sh: float64): string =
  ## The classification histogram rides along on EVERY branch -- including the
  ## FAIL and INCONCLUSIVE ones, because a broken classifier and a broken
  ## placement are independent failures, and the branch that hides one behind
  ## the other is the branch that costs a session.
  neVerdictBody(sw, sh) & "  [" & neClsHistText() & " -- " & neClsVerdict() & "]"

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
    # OWNERSHIP AND LEAKS. A canvas we FOUND belongs to the game and is left
    # exactly alone. A canvas WE created is ours, and the raid is over: it must
    # not survive into the next one, where it would sit above the HUD holding a
    # pool of stale boxes. This is the whole reason DontDestroyOnLoad was NOT
    # used -- a per-raid canvas that is destroyed at the gate is far easier to
    # reason about than a process-lifetime one.
    if gNeOwnCanvasGo != nil:
      neDestroyPool()
      neDestroyOwnCanvas("the raid ended (" &
                         readCString(cNeRefusalText(gate)) & ")")
      gNePhase0Done = false
      gNeSeeded = false
      gNeCreateTried = false
      gNeParentLine = "parent readback not run yet (torn down)"
      gNeState = NeIdle
    elif gNeState == NeRun and not duOk(gNeCanvasTr, 0x20'i32):
      neDestroyPool()
      gNeCanvasGo = nil
      gNeCanvasTr = nil
      gNeCanvasOrigin = NeOriginNone
      gNePhase0Done = false        # the canvas died: re-ask the shared finder
      gNeSeeded = false
      gNeCreateTried = false
      gNeParentLine = "parent readback not run yet (torn down)"
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
  of NeSettle:
    neSettleStep()
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
    if not neLive(gNeCanvasTr) or not neActiveInHier(gNeCanvasGo):
      # the raid canvas went away (scene change): drop the pool and rediscover
      neDestroyPool()
      neDestroyOwnCanvas("the canvas stopped being alive/active in NeRun")
      gNeCanvasGo = nil
      gNeCanvasTr = nil
      gNeCanvasOrigin = NeOriginNone
      gNePhase0Done = false        # the canvas died: re-ask the shared finder
      gNeSeeded = false
      gNeCreateTried = false
      gNeParentLine = "parent readback not run yet (torn down)"
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
  let wasDiscovering = gNeState == NeDiscover
  if cNeTickGuarded(nil) == nil:
    if wasDiscovering:
      # Discovery has its OWN ledger. The walk touches thousands of foreign
      # objects per raid; letting it spend the steady-state budget is what
      # killed the feature after six frames. It still self-disables -- at its
      # own, larger cap, with its own reason.
      inc gNeDiscFaults
      # SEED OR WALK -- NEVER BOTH UNDER ONE NAME. `gNeSeeded` is set only
      # after a seed has fully succeeded, so "not seeded" means the fault
      # happened at or before seeding and the walk had not started. The old
      # message called every discovery fault a "WALK" fault; that is how 24
      # faults reported `visited=0 budgetLeft=20000 head=0/0` -- a walk that
      # provably never ran -- and told us nothing.
      let inSeed = not gNeSeeded
      # PER-ROOT FAULT ISOLATION. The guard is not re-entrant, so the seed can
      # not wrap each root in its own; instead it records the index it is IN
      # FLIGHT on, and that index becomes a permanent skip here. Without this,
      # one unconvertible root among 178 burns a discovery fault per frame and
      # the feature self-disables before the walk has ever run -- which is
      # precisely what was measured.
      if inSeed and gNeSeedInFlight >= 0:
        if gNeSeedSkip.len < int(cNeMaxSeedSkips()) and
           not neSeedSkipped(gNeSeedInFlight):
          gNeSeedSkip.add int32(gNeSeedInFlight)
        warn "natesp: scene root index " & $gNeSeedInFlight & " of " &
             $gNeSeedRootsGot & " FAULTED during " &
             neSeedStepName(gNeSeedStep) & "; it is now permanently SKIPPED " &
             "(" & $gNeSeedSkip.len & " of " & $int(cNeMaxSeedSkips()) &
             " skip slots used) and the next attempt steps over it. This is " &
             "counted as rootsFaulted, which is NOT rootsSkippedDead."
        gNeSeedInFlight = -1
      warn "natesp: " & (if inSeed: "SEEDING" else: "the canvas WALK") &
           " faulted (" & $gNeDiscFaults & " of " &
           $int(cNeMaxDiscFaults()) & " discovery faults; the steady-state " &
           "budget is untouched at " & $int(cNeFaultCount()) & "). Fake nulls " &
           "are skipped, not faulted, so this was something else. " &
           (if inSeed:
              "The breadth-first walk had NOT started -- nothing was queued and " &
              "no budget was spent, so this is NOT a walk fault. " &
              neSeedLedger() & ". `step` is set before each call that can " &
              "fault, so it names the call that did; `lastInternalCall` is the " &
              "native breadcrumb from the same body."
            else:
              "Walk so far: visited=" & $gNeVisited & " fakeNullsSkipped=" &
              $gNeFakeNull & " head=" & $gNeHead & "/" & $gNeQueue.len &
              " lastInternalCall=\"" & neCrumb() &
              "\"; the walk RESUMES at the next node, it does not restart.")
      if gNeDiscFaults >= int(cNeMaxDiscFaults()):
        neRefuse(NeRDiscFaulted)
    else:
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
    # The lifecycle gate, stated separately and never folded into the verdict:
    # "no boxes" because the player has not deployed is a different fact from
    # "no boxes" because the placement failed, and one line that says both is
    # a line that cannot fail.
    okLog "natesp: raid phase = " & rpPhaseName(rpPhase()) & " -- " & rpWhy() &
          "  [" & rpSignals() & "]"

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
