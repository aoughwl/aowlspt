## ===========================================================================
## nuikit -- THE NATIVE-UI TOOLKIT A MOD ACTUALLY CALLS
##
## `nativeui.nim` proved the primitives; this is the layer that makes them
## USABLE without re-deriving the sequence by hand every time. It adds exactly
## three things and nothing else:
##
##   1. TWO CONSTRUCTORS, `nuPanel` and `nuLabel`, that encode the ONE ordering
##      proven live on 2026-08-30 (IMAGEPROOF VERDICT = PASS). Get the order
##      wrong and every call still succeeds while nothing renders, which is the
##      failure mode this whole layer exists to end.
##   2. A HANDLE TABLE WITH GENERATION COUNTERS. This is the safety core. A mod
##      that keeps a handle across a scene change must get a NAMED REFUSAL, not
##      a dereference of a recycled slot. Unity's fake-null makes the naive
##      version lethal: a destroyed UnityEngine.Object stays perfectly READABLE
##      with `m_CachedPtr` zeroed, so a pointer check passes and the next
##      internal call dies inside Unity's own C++. Readability is not liveness.
##   3. `nuCanvasFind` -- THE HOST'S ONE CANVAS-ACQUISITION FUNCTION.
##
## WHOSE CANVAS DISCOVERY THIS IS. It is the LIVE INSPECTOR'S, consumed:
## `iSceneRoots` + `iVisComponent("Canvas")` + `Canvas::get_renderMode`, the
## path that reliably returns ~16 scene roots. That is why this file is
## `include`d AFTER `inspect.nim` -- the inspector's walkers are not in scope
## any earlier.
##
## THE CONSOLIDATION, 2026-08-30. There were three answers to "where is a
## Canvas" and they disagreed:
##   * `natesp.nim` breadth-first from every scene root. MEASURED failing:
##     `visited=20000 candidates=0 deepest=3/8 scope=TRUNCATED` -- it spent the
##     whole budget on map geometry and never reached UI. It is now a FALLBACK
##     behind `nuCanvasFind`, not a rival implementation.
##   * `nativeui.nim` Stage C never had one AT ALL. Its IMAGEPROOF PASS did not
##     find a Canvas: it walked `SettingsTab._createdControls` for a live UI
##     control (`mi2FindTmp`) and parented under that control's GameObject, and
##     Unity's OnEnable then populated `Graphic.m_Canvas` by ANCESTOR WALK. That
##     path needs a SettingsTab and exists only on the settings screen; it is
##     not reusable in a raid and is deliberately left alone.
##   * this file, which is the one that generalises, and now carries the
##     acceptance rule natesp paid for.
##
## WHERE THIS SITS RELATIVE TO `aowlui.nim`. `aowlui` is a SCREEN-level retained
## framework (panels/labels/toggles/tabs/config binding) over two backends. This
## is the ELEMENT level underneath it: one handle, one GameObject, no retained
## screen, no reset. A mod that wants a whole settings screen should use
## `aowlui`; a mod that wants to put one box and one caption on screen and keep
## them for a while should use this. They are not rivals, but the overlap is
## real and is called out in `docs/NATIVE_UI.md`.
##
## GUARDS. Every entry point here assumes THE CALLER IS ALREADY INSIDE ONE
## `aowl_p_p_seh`, exactly like `nuCreate`/`nuAdd` do. This file opens NONE of
## its own: the guard is not re-entrant and a nested inner guard DISARMS the
## outer one. The self-test rides invoke2's postfix drain, which is already
## guarded, for the same reason `auProofRun` does.
##
## ALLOCATION. Everything managed is allocated ONCE, at creation. Every setter
## is a plain field write or a byte-verified setter call. Strings go through
## `nuStr`, which interns, so even `nuSetText` in a per-frame path allocates at
## most once per distinct string for the life of the process.
## ===========================================================================

# ---------------------------------------------------------------------------
# THE HANDLE TABLE, in C.
#
# In C rather than the ABI header on purpose: touching `abi/*.h` correctly drops
# every build cache and forces an 18-minute full rebuild, and this table has no
# other consumer. It is a fixed 64 entries -- capped by construction, so no
# iteration over it can run away.
#
# A handle is  (generation << 16) | (index + 1)  as a uint32.
#   * index+1, so the all-zero handle is ALWAYS invalid, even at generation 0.
#   * the generation is bumped on every allocation and compared on every lookup,
#     so a handle to a slot that has since been freed and REUSED resolves to
#     STALE rather than to somebody else's panel. That is the single case the
#     naive index-only handle gets wrong, and it is the one that crashes.
# ---------------------------------------------------------------------------
{.emit: """
/* RAISED 64 -> 256 on 2026-08-31, deliberately, for the native inventory
 * screen. This is the bound the whole table's safety rests on, so it is a
 * measured number and not a round one:
 *
 *   colorwidget   6 widgets x (1 swatch + 3 tracks + 3 fills + 1 readout) = 48
 *   invui         1 backdrop + 1 title + 3 search + 2 headers
 *                 + 2 columns x 14 rows x (panel + label) = 56
 *                 + 2 button + 1 note                            = 65
 *   natesp/selftest and any future single-element caller         ~ 16
 *                                                        total  ~ 129
 *
 * 64 was not enough for ONE inventory column, let alone two beside the colour
 * widgets: `nuPanel` would have started returning "the handle table is full",
 * which is a correct refusal and a screen with half its rows missing. 256
 * leaves roughly a 2x margin over the measured need and costs 256 * 40 bytes
 * ~= 10 KB of static BSS, which is nothing.
 *
 * What did NOT change: the loop in `aowl_nk_alloc` is still bounded by this
 * constant, `aowl_nk_slot_of` still range-checks against it, and the handle is
 * still (gen << 16) | (idx + 1) -- 256 fits in the low 16 bits with three
 * orders of magnitude to spare, so the encoding is untouched. Raising this
 * further than 0xFFFF would collide the index with the generation field; if
 * that is ever wanted, the encoding has to change first. */
#define AOWL_NK_MAX 256

typedef struct {
    void*    go;      /* the GameObject                          */
    void*    rt;      /* its RectTransform                       */
    void*    comp;    /* the Image (panel) or TMP_Text (label)   */
    int      kind;    /* AOWL_NK_PANEL / AOWL_NK_LABEL           */
    unsigned gen;     /* bumped per allocation; 0 is never used  */
    int      used;
} aowl_nk_slot_t;

static aowl_nk_slot_t g_aowl_nk[AOWL_NK_MAX];
static unsigned       g_aowl_nk_gen  = 1u;
static int            g_aowl_nk_live = 0;

/* Three refusals, told apart on purpose: "you handed me nonsense",
   "you handed me something you already destroyed", and "you handed me
   something whose slot has since been given to somebody else". Collapsing
   them would make the log say the same thing for three different bugs. */
#define AOWL_NK_ERR_RANGE  (-1)
#define AOWL_NK_ERR_FREED  (-2)
#define AOWL_NK_ERR_STALE  (-3)

static int aowl_nk_slot_of(unsigned h) {
    unsigned idx = (h & 0xFFFFu);
    unsigned gen = (h >> 16) & 0xFFFFu;
    int i;
    if (idx == 0u || idx > (unsigned)AOWL_NK_MAX) return AOWL_NK_ERR_RANGE;
    i = (int)idx - 1;
    if (!g_aowl_nk[i].used)          return AOWL_NK_ERR_FREED;
    if (g_aowl_nk[i].gen != gen)     return AOWL_NK_ERR_STALE;
    return i;
}

static unsigned aowl_nk_alloc(void* go, void* rt, void* comp, int kind) {
    int i;
    for (i = 0; i < AOWL_NK_MAX; ++i) {
        if (!g_aowl_nk[i].used) {
            g_aowl_nk[i].used = 1;
            g_aowl_nk[i].go   = go;
            g_aowl_nk[i].rt   = rt;
            g_aowl_nk[i].comp = comp;
            g_aowl_nk[i].kind = kind;
            /* wrap short of 0xFFFF and never to 0: generation 0 must not be a
               legal live generation, or a zeroed slot would authenticate. */
            if (g_aowl_nk_gen == 0u || g_aowl_nk_gen >= 0xFFFFu)
                g_aowl_nk_gen = 1u;
            g_aowl_nk[i].gen = g_aowl_nk_gen++;
            g_aowl_nk_live++;
            return ((g_aowl_nk[i].gen & 0xFFFFu) << 16) | (unsigned)(i + 1);
        }
    }
    return 0u;   /* table full -- a refusal, never an overwrite */
}

static int   aowl_nk_resolve(unsigned h)   { return aowl_nk_slot_of(h); }
static void* aowl_nk_go(unsigned h)   { int i=aowl_nk_slot_of(h); return i<0?(void*)0:g_aowl_nk[i].go; }
static void* aowl_nk_rt(unsigned h)   { int i=aowl_nk_slot_of(h); return i<0?(void*)0:g_aowl_nk[i].rt; }
static void* aowl_nk_comp(unsigned h) { int i=aowl_nk_slot_of(h); return i<0?(void*)0:g_aowl_nk[i].comp; }
static int   aowl_nk_kind(unsigned h) { int i=aowl_nk_slot_of(h); return i<0?0:g_aowl_nk[i].kind; }

static int aowl_nk_release(unsigned h) {
    int i = aowl_nk_slot_of(h);
    if (i < 0) return 0;
    g_aowl_nk[i].used = 0;
    g_aowl_nk[i].go   = (void*)0;
    g_aowl_nk[i].rt   = (void*)0;
    g_aowl_nk[i].comp = (void*)0;
    g_aowl_nk[i].kind = 0;
    /* gen is deliberately NOT cleared: the next alloc gives this slot a NEW
       generation, and every handle carrying the old one now reads STALE. */
    if (g_aowl_nk_live > 0) g_aowl_nk_live--;
    return 1;
}

static int aowl_nk_live_count(void) { return g_aowl_nk_live; }
static int aowl_nk_capacity(void)   { return AOWL_NK_MAX; }
static unsigned aowl_nk_at(int i) {
    if (i < 0 || i >= AOWL_NK_MAX || !g_aowl_nk[i].used) return 0u;
    return ((g_aowl_nk[i].gen & 0xFFFFu) << 16) | (unsigned)(i + 1);
}
""".}

proc cNkResolve(h: uint32): int32 {.importc: "aowl_nk_resolve", nodecl.}
proc cNkGo(h: uint32): Il2CppPtr {.importc: "aowl_nk_go", nodecl.}
proc cNkRt(h: uint32): Il2CppPtr {.importc: "aowl_nk_rt", nodecl.}
proc cNkComp(h: uint32): Il2CppPtr {.importc: "aowl_nk_comp", nodecl.}
proc cNkKind(h: uint32): int32 {.importc: "aowl_nk_kind", nodecl.}
proc cNkAlloc(go, rt, comp: Il2CppPtr; kind: int32): uint32 {.
  importc: "aowl_nk_alloc", nodecl.}
proc cNkRelease(h: uint32): int32 {.importc: "aowl_nk_release", nodecl.}
proc cNkLiveCount(): int32 {.importc: "aowl_nk_live_count", nodecl.}
proc cNkCapacity(): int32 {.importc: "aowl_nk_capacity", nodecl.}
proc cNkAt(i: int32): uint32 {.importc: "aowl_nk_at", nodecl.}

# ---------------------------------------------------------------------------
# The public handle type and the element kinds.
# ---------------------------------------------------------------------------
type
  NuElem* = distinct uint32     ## an opaque, generation-checked element handle

const
  nuNone* = NuElem(0'u32)       ## the handle every refusal returns

const
  NkPanel = 1'i32
  NkLabel = 2'i32

proc nuValidHandle*(e: NuElem): bool =
  ## Cheap syntactic check. NOT a liveness check -- see `nuLive`.
  cNkResolve(uint32(e)) >= 0'i32

proc nkKindName(k: int32): string =
  case int(k)
  of 1: "panel (UnityEngine.UI.Image)"
  of 2: "label (TMPro.TextMeshProUGUI)"
  else: "unknown"

proc nkRefusalName(code: int32): string =
  ## The refusal, named. A layer that says "invalid handle" for three different
  ## bugs teaches the next reader nothing.
  case int(code)
  of -1: "OUT OF RANGE -- this is not a handle this toolkit ever issued " &
         "(index 0 or beyond the 64-entry table)"
  of -2: "RELEASED -- the element behind this handle was destroyed through " &
         "nuDestroy/nuDestroyAllElems; the handle is spent"
  of -3: "STALE GENERATION -- the slot exists but has since been re-issued to " &
         "a DIFFERENT element. This is the case that would crash if handles " &
         "were bare indices: it is exactly what a handle kept across a scene " &
         "change looks like"
  else: "resolved"

# ---------------------------------------------------------------------------
# Flags. Both default OFF.
#   nativeUiKit      -- the toolkit answers at all (also needs `nativeUi`)
#   nativeUiKitProof -- additionally run the one-shot toolkit self-test
# ---------------------------------------------------------------------------
var gNkOn = false
var gNkProof = false
var gNkProofDone = false

## Self-disable. This layer has no guard of its own (§3), so it cannot count
## FAULTS; what it can count is HARD REFUSALS -- a construction step that the
## underlying primitive declined. Eight of those in a session means the build
## is not the one these RVAs came from, or the canvas walk is wrong, and
## continuing would only reprint the same refusal forever.
const NkMaxRefusals = 8
var gNkRefusals = 0
var gNkOff = false

proc nkRefuse(what, why: string) =
  inc gNkRefusals
  warn "nuikit: " & what & " REFUSED -- " & why
  if gNkRefusals >= NkMaxRefusals and not gNkOff:
    gNkOff = true
    warn "nuikit: SELF-DISABLED after " & $gNkRefusals & " hard refusals. " &
         "Every further call returns nuNone without touching the client. " &
         "This is a refusal, not a verdict about any one element."

proc nkReady(what: string): bool =
  ## The four gates every entry point passes, in the order that makes the log
  ## say which one stopped it.
  if not gNkOn:
    return false                              # flag off: silent by design
  if gNkOff:
    return false
  if not gNuOn:
    nkRefuse(what, "the `nativeUi` primitive layer is OFF; this toolkit is a " &
                   "facade over it and can do nothing on its own")
    return false
  if cNuDisabled() != 0'i32:
    nkRefuse(what, "the nativeui layer has SELF-DISABLED after " &
                   $int(cNuFaultCount()) & " fault(s); refusing to build more")
    return false
  true

# ---------------------------------------------------------------------------
# RESOLVE -- the one function every entry point starts with.
#
# Three questions, in this order, because each is meaningless without the one
# before it: is the handle ours, does its generation still match, and is the
# GameObject still ALIVE by Unity's own reckoning.
# ---------------------------------------------------------------------------
proc nkResolve(e: NuElem; what: string;
               go, rt, comp: var Il2CppPtr; kind: var int32): bool =
  go = nil; rt = nil; comp = nil; kind = 0'i32
  let slot = cNkResolve(uint32(e))
  if slot < 0'i32:
    nkRefuse(what, "handle 0x" & hexOf(uint64(uint32(e))) & ": " &
                   nkRefusalName(slot))
    return false
  go = cNkGo(uint32(e))
  rt = cNkRt(uint32(e))
  comp = cNkComp(uint32(e))
  kind = cNkKind(uint32(e))
  if not nuOk(go, 0x10'i32) or not nuOk(rt, 0x10'i32):
    nkRefuse(what, "handle 0x" & hexOf(uint64(uint32(e))) & ": its GameObject " &
                   "or RectTransform is no longer readable")
    return false
  # THE FAKE-NULL GATE. Readability got us here; it is not the question.
  if not nuAlive(go):
    nkRefuse(what, "handle 0x" & hexOf(uint64(uint32(e))) & ": Unity reports " &
                   "the GameObject DESTROYED (op_Implicit false). It is still " &
                   "perfectly readable with m_CachedPtr zeroed -- which is why " &
                   "a pointer check would have passed and the next internal " &
                   "call would have died inside Unity's C++. Releasing the slot")
    discard cNkRelease(uint32(e))
    return false
  true

proc nuLive*(e: NuElem): bool =
  ## Is the element behind this handle still one Unity would talk to? The
  ## honest question a mod should ask before a per-frame update. Does not log.
  let slot = cNkResolve(uint32(e))
  if slot < 0'i32: return false
  let go = cNkGo(uint32(e))
  nuOk(go, 0x10'i32) and nuAlive(go)

proc nuElemCount*(): int = int(cNkLiveCount())
proc nuElemCapacity*(): int = int(cNkCapacity())

# ---------------------------------------------------------------------------
# CANVAS DISCOVERY -- the inspector's path, consumed.
#
# `anchor` is a LIVE object the caller has already validated. It is REQUIRED,
# and that is not pedantry: `iSceneRoots(nil)` falls back to `gInspPreloader`,
# which only the live inspector's rider ever writes, so a mod that passed nil
# would get "no roots" on every run the inspector was not also driving.
# ---------------------------------------------------------------------------
## THE ROOT-ASK CAP, and why it moved from 64 to 512.
##
## MEASURED (integ-beta6 + 59b5dd7, DEPLOYED raid, natesp phase 0):
##   verdict=ABSENT rootsSeen=178 walked=64 asked=64 candidates=0 scope=TRUNCATED
##
## `asked=64` is the old cap, not a property of the scene. 114 of the 178 roots
## were never asked, so `ABSENT` was a TRUNCATION ARTIFACT: a verdict that could
## not have said anything else, which is CLAUDE.md 9b exactly. It is `scope`
## that made that visible, and `scope` is what has to read EXHAUSTIVE before
## `ABSENT` is allowed to mean anything -- in particular before natesp is
## allowed to conclude there is no canvas and create its own.
##
## THE COST IS NOT THE REASON IT WAS 64. Asking a root for a component is ONE
## `iVisComponent` call. 178 of them, once, in a seed that already enumerates
## those same roots, is nothing next to the 20,000-node breadth-first walk it
## replaces -- the walk this function exists to avoid.
##
## The loop still SIZES ITSELF from `roots.len`; 512 is only a ceiling, chosen
## to match natesp's own `NeMaxRootUniverse`, so the two layers cannot disagree
## about how many roots exist. Rule 4 (cap every iteration) is satisfied by the
## ceiling; rule "a check that cannot fail is the bug" is satisfied by `scope`
## still going TRUNCATED, loudly, if a scene ever exceeds it.
const NkMaxRoots = 512

var gNkCanvasGo: Il2CppPtr = nil     ## cached, but re-validated on every call

type
  NuCanvasPick* = object
    ## THE result of canvas discovery, for every caller in the host.
    ##
    ## `verdict` is THREE-STATE on purpose (CLAUDE.md 9b). It is the field that
    ## keeps "we searched the right place and there is no canvas" apart from
    ## "we never got to look", and no consolidation may collapse it:
    ##   "FOUND"        -- `go`/`tr`/`comp` are bound and passed acceptance
    ##   "ABSENT"       -- roots WERE examined and none qualified. An answer.
    ##   "INCONCLUSIVE" -- nothing was examined (no anchor, no roots, or the
    ##                     component ask failed on every root). NOT an answer.
    go*, tr*, comp*: Il2CppPtr   ## GameObject / RectTransform / Canvas component
    w*, h*: float32              ## the winner's rect, READ BACK, not assumed
    rootsSeen*: int              ## roots handed to us
    walked*: int                 ## roots we actually examined
    asked*: int                  ## roots iVisComponent could ASK (could-look)
    dead*: int                   ## roots skipped as destroyed/unreadable. A
                                 ## dead root HAS no canvas, so this does NOT
                                 ## make the answer incomplete.
    unaskable*: int              ## roots that were ALIVE and whose component
                                 ## ask still failed. THIS is what makes an
                                 ## answer incomplete, and it is counted apart
                                 ## from `dead` for exactly that reason.
    candidates*: int             ## roots that carried a Canvas at all
    rejected*: int               ## Canvases that failed the acceptance rule
    worldSpace*: int             ## Canvases skipped as WorldSpace(2)
    askCap*: int                 ## the ceiling in force; reported so a reader
                                 ## never has to guess whether `asked` is the
                                 ## scene's size or ours
    scope*: string               ## "EXHAUSTIVE" | "TRUNCATED"
    verdict*: string
    why*: string

proc nuCanvasLedger*(p: NuCanvasPick): string =
  "canvas: verdict=" & p.verdict & " rootsSeen=" & $p.rootsSeen &
  " walked=" & $p.walked & " asked=" & $p.asked &
  " dead=" & $p.dead & " unaskable=" & $p.unaskable &
  " candidates=" & $p.candidates & " rejected=" & $p.rejected &
  " worldSpace=" & $p.worldSpace & " askCap=" & $p.askCap &
  " scope=" & p.scope &
  (if p.verdict == "FOUND":
     " w=" & formatFloat(float64(p.w), ffDecimal, 1) &
     " h=" & formatFloat(float64(p.h), ffDecimal, 1)
   else: "") &
  " why=\"" & p.why & "\""

proc nuCanvasFind*(anchor: Il2CppPtr; minPx: float32;
                   pick: var NuCanvasPick): bool =
  ## THE ONE canvas-acquisition function in this host. `nuFindCanvas` forwards
  ## to it and natesp calls it directly; there is no second implementation.
  ##
  ## WHY THE ROOT WALK AND NOT A TREE WALK. Measured, 2026-08-30: natesp's own
  ## breadth-first descent spent its entire 20,000-node budget on map geometry
  ## and reported `candidates=0 deepest=3/8 scope=TRUNCATED` -- it never got
  ## deep enough to reach any UI. A Canvas is at or very near a SCENE ROOT, so
  ## asking each root directly for a `Canvas` component costs ~16 questions
  ## instead of 20,000 and cannot truncate before reaching the UI.
  ##
  ## TYPES AT EVERY HOP, because a Transform passes BOTH readability and
  ## liveness (it IS a UnityEngine.Object) and that is how the last type
  ## confusion survived four rounds:
  ##   `iSceneRoots` -> seq of TRANSFORM (converted at the inspector boundary)
  ##   `iVisComponent(transform, "Canvas")` -> the CANVAS COMPONENT
  ##   `nuGameObjectOf(canvas)` -> GAMEOBJECT
  ##   `nuTransformOf(go)` -> the canvas's RECTTRANSFORM (what callers parent to)
  ##
  ## ACCEPTANCE (natesp's rule, kept verbatim and now applied for everyone):
  ## alive AND activeInHierarchy AND the rect READS BACK >= `minPx` on BOTH
  ## axes. LARGEST AREA WINS. `minPx <= 0` disables only the size test; the
  ## liveness and active tests are never optional.
  ##
  ## GUARDS: this proc opens NO `aowl_p_p_seh` of its own -- like the rest of
  ## nuikit it is designed to be called from INSIDE the caller's single guarded
  ## region (natesp's tick body, invoke2's postfix). Nesting would disarm the
  ## outer guard. Every pointer hop is `nuOk` + `nuAlive` checked and the root
  ## loop is capped at `NkMaxRoots`.
  ##
  ## It deliberately does NOT go through `nkReady`: gating natesp's canvas
  ## discovery on the `nativeUiKit` flag would be a hidden coupling between two
  ## unrelated features. It requires only the `nativeUi` primitive layer, which
  ## every caller already needs to create anything at all.
  pick = NuCanvasPick(go: nil, tr: nil, comp: nil, w: 0'f32, h: 0'f32,
                      rootsSeen: 0, walked: 0, asked: 0, dead: 0,
                      unaskable: 0, candidates: 0,
                      rejected: 0, worldSpace: 0, askCap: NkMaxRoots,
                      scope: "EXHAUSTIVE",
                      verdict: "INCONCLUSIVE", why: "")
  if not gNuOn or cNuDisabled() != 0'i32:
    pick.why = "the nativeUi primitive layer is OFF or self-disabled; nothing " &
               "was examined"
    return false
  if not nuOk(anchor, 0x10'i32) or not nuAlive(anchor):
    pick.why = "the anchor is null, unreadable or destroyed. iSceneRoots(nil) " &
               "falls back to the inspector's own preloader pointer, so " &
               "guessing here would silently search nothing"
    return false

  var roots: seq[Il2CppPtr] = @[]
  discard iSceneRoots(roots, false, anchor)
  pick.rootsSeen = roots.len
  if roots.len == 0:
    pick.why = "the scene-root walk returned NO roots at all, so nothing was " &
               "examined. This is not absence"
    return false

  var lim = roots.len
  if lim > NkMaxRoots:
    lim = NkMaxRoots                            # capped iteration
    pick.scope = "TRUNCATED"
  var bestArea = 0'f32
  for i in 0 ..< lim:
    let rootTr = roots[i]                       # TRANSFORM, by iSceneRoots' contract
    if not nuOk(rootTr, 0x10'i32) or not nuAlive(rootTr):
      inc pick.dead                             # a destroyed root has no canvas
      continue
    inc pick.walked
    var comp: Il2CppPtr = nil                   # the CANVAS COMPONENT
    var why = ""
    if not iVisComponent(rootTr, "Canvas", comp, why):
      inc pick.unaskable                        # could not look != absent
      continue
    inc pick.asked
    if comp == nil: continue
    if not nuOk(comp, 0x10'i32) or not nuAlive(comp): continue
    inc pick.candidates
    var mode = -1
    var w2 = ""
    if iVisI32("Canvas::get_renderMode", comp, mode, w2) and mode == 2:
      # WorldSpace: UI parented here is somewhere in the map, not on the
      # screen. Accepting it would be an INVISIBLE SUCCESS.
      inc pick.worldSpace
      continue
    let go = nuGameObjectOf(comp)               # GAMEOBJECT
    if go == nil or not nuOk(go, 0x10'i32) or not nuAlive(go):
      inc pick.rejected
      continue
    if not nuActiveInHierarchy(go):
      inc pick.rejected                         # inactive: renders nothing
      continue
    let tr = nuTransformOf(go)                  # RECTTRANSFORM
    if tr == nil or not nuOk(tr, 0x10'i32) or not nuAlive(tr):
      inc pick.rejected
      continue
    let (okR, _, _, rw, rh) = nuGetRect(tr)     # READ BACK, never assumed
    if not okR or not (rw >= minPx) or not (rh >= minPx):
      inc pick.rejected
      continue
    let area = rw * rh
    if area > bestArea:
      bestArea = area
      pick.comp = comp
      pick.go = go
      pick.tr = tr
      pick.w = rw
      pick.h = rh

  if pick.go == nil:
    if pick.asked == 0:
      pick.verdict = "INCONCLUSIVE"
      pick.why = "walked " & $pick.walked & " root(s) and could ask NONE of " &
                 "them for a Canvas component. Nothing was examined"
    elif pick.scope != "EXHAUSTIVE" or pick.unaskable > 0:
      # THE VERDICT THAT USED TO BE UNFALSIFIABLE. Before the cap moved to 512,
      # a raid reported `rootsSeen=178 asked=64 scope=TRUNCATED` and STILL said
      # ABSENT -- 114 roots never asked, and a verdict that could not have come
      # out any other way. ABSENT now REQUIRES that every root the enumeration
      # produced was actually asked.
      pick.verdict = "INCONCLUSIVE"
      pick.scope = "TRUNCATED"
      pick.why = "the scene produced " & $pick.rootsSeen & " root(s); " &
                 $pick.asked & " were asked, " & $pick.dead &
                 " were destroyed (which IS an answer for those) and " &
                 $pick.unaskable & " were alive but could NOT be asked" &
                 (if pick.rootsSeen > pick.askCap:
                    ", and the ask cap of " & $pick.askCap & " cut the list short"
                  else: "") &
                 ". A root that was never asked cannot be reported as having " &
                 "no canvas, so this is NOT an absence"
    else:
      pick.verdict = "ABSENT"
      pick.why = "asked EVERY live root -- " & $pick.asked & " of " &
                 $pick.rootsSeen & " (" & $pick.dead &
                 " destroyed, 0 unaskable, ask cap " & $pick.askCap &
                 " not reached). " & $pick.candidates &
                 " carried a Canvas, " & $pick.worldSpace & " were WorldSpace " &
                 "and " & $pick.rejected & " failed alive+active+>=" &
                 formatFloat(float64(minPx), ffDecimal, 1) &
                 "px. Nothing was truncated, so this is a REAL absence at " &
                 "root level -- a canvas NESTED below a root is still possible " &
                 "and is what the caller's fallback walk is for"
    return false
  pick.verdict = "FOUND"
  pick.why = "largest of " & $pick.candidates & " Canvas candidate(s) that " &
             "passed alive+activeInHierarchy+rect readback"
  true

proc nuFindCanvas*(anchor: Il2CppPtr): Il2CppPtr =
  ## The GameObject of a live, screen-space Canvas to parent UI into, or nil.
  ## A THIN FORWARD to `nuCanvasFind` -- kept only so existing callers do not
  ## change. It applies no minimum size (`minPx = 0`), which is why nuikit's
  ## self-test can still parent into a small menu canvas.
  result = nil
  if not nkReady("findCanvas"): return nil

  # The cache, re-checked. A cached canvas that died in a scene change is
  # exactly the fake-null case, so `nuAlive` decides, not non-nil.
  if gNkCanvasGo != nil:
    if nuOk(gNkCanvasGo, 0x10'i32) and nuAlive(gNkCanvasGo):
      return gNkCanvasGo
    okLog "nuikit: the cached canvas is no longer alive (a scene change is the " &
          "usual reason); re-walking"
    gNkCanvasGo = nil

  var pick = NuCanvasPick()
  if not nuCanvasFind(anchor, 0'f32, pick):
    nkRefuse("findCanvas", nuCanvasLedger(pick))
    return nil
  gNkCanvasGo = pick.go
  okLog "nuikit: " & nuCanvasLedger(pick) & " Canvas=0x" &
        hexOf(cast[uint64](pick.comp)) & " GameObject=0x" &
        hexOf(cast[uint64](pick.go)) &
        " -- via nuCanvasFind, the host's ONE canvas-acquisition function"
  result = pick.go

# ---------------------------------------------------------------------------
# CONSTRUCTORS
#
# The ordering below is not a style choice. It is the sequence that produced
# `IMAGEPROOF VERDICT = PASS` on 2026-08-30, and each step is here because
# moving it broke something:
#
#   GameObject -> AddComponent<RectTransform> -> SetParentAndAlign -> layer 5
#     -> SetActive(FALSE) -> AddComponent<Graphic> -> [wire deps] -> layout
#     -> SetActive(true) -> set_color -> SetAllDirty
#
# SetActive(false) BEFORE the Graphic add is the one that is not obvious: on an
# ACTIVE GameObject the add IS the render -- Awake/OnEnable fire synchronously
# from inside AddComponent and reach for a material and a canvas that a
# from-scratch component does not have yet. Deactivating first is the only
# window there is between "the component exists" and "the component runs".
# ---------------------------------------------------------------------------
proc nuPanel*(parentGo: Il2CppPtr; x, y, w, h: float32;
              r, g, b, a: float32; name: string = "aowl-panel"): NuElem =
  ## A solid coloured quad -- a `UnityEngine.UI.Image` with NO sprite, which is
  ## legal: with `m_Type == Simple` and a null sprite the Graphic emits one quad
  ## over its rect in `m_Color`. That is exactly a panel, and it needs no asset.
  ##
  ## `parentGo` should be `nuFindCanvas(anchor)` or a GameObject already under
  ## one; a Graphic with no live Canvas ancestor is inert however correct
  ## everything else is. Colours are 0..1 floats, `a` is alpha -- alpha 0 is the
  ## invisible success this signature makes you type out.
  ##
  ## Position is top-left anchored: (x, y) is offset from the canvas top-left,
  ## with y NEGATIVE going down, the Unity convention the proof used.
  result = nuNone
  if not nkReady("panel(\"" & name & "\")"): return nuNone
  if not nuOk(parentGo, 0x10'i32) or not nuAlive(parentGo):
    nkRefuse("panel(\"" & name & "\")", "the parent is null, unreadable or a " &
             "destroyed Unity object")
    return nuNone

  let go = nuCreate(name, parentGo)
  if go == nil:
    nkRefuse("panel(\"" & name & "\")", "the GameObject could not be created " &
             "(the primitive layer logged the reason above)")
    return nuNone
  let rt = nuAdd(go, NuKindRectTransform)
  if rt == nil:
    nkRefuse("panel(\"" & name & "\")", "AddComponent<RectTransform> yielded " &
             "nothing usable; tearing the GameObject down")
    discard nuDestroy(go); return nuNone
  if not nuParentAligned(go, parentGo):
    nkRefuse("panel(\"" & name & "\")", "SetParentAndAlign failed; a Graphic " &
             "with no Canvas ancestor is inert, so refusing to continue")
    discard nuDestroy(go); return nuNone
  discard nuSetLayer(go, 5'i32)              # Unity's built-in `UI` layer
  if not nuSetActive(go, false):
    nkRefuse("panel(\"" & name & "\")", "could not deactivate before the " &
             "Graphic add; on an active object Awake fires from inside " &
             "AddComponent and there is no window to wire anything")
    discard nuDestroy(go); return nuNone

  let img = nuAdd(go, NuKindImage)
  if img == nil:
    nkRefuse("panel(\"" & name & "\")", "AddComponent<UnityEngine.UI.Image> " &
             "yielded nothing usable (slot state " &
             nuSlotStateName(cNuSlotState(NuKindImage)) & ")")
    discard nuDestroy(go); return nuNone

  if not nuLayout(rt, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32,
                  w, h, x, y):
    nkRefuse("panel(\"" & name & "\")", "layout refused this size/position, so " &
             "the Image could never have a renderable rect")
    discard nuDestroy(go); return nuNone
  discard nuSetActive(go, true)
  discard nuImgSetColor(img, r, g, b, a)
  let dirtyFn = nuFn(NuTGrSetAllDirty)
  if dirtyFn != nil and nuOk(img, 0x40'i32):
    discard cNuCallPP(dirtyFn, img)

  let hnd = cNkAlloc(go, rt, img, NkPanel)
  if hnd == 0'u32:
    nkRefuse("panel(\"" & name & "\")", "the handle table is full (" &
             $int(cNkCapacity()) & " entries). Destroying the element rather " &
             "than handing back an untracked GameObject that could never be " &
             "torn down")
    discard nuDestroy(go); return nuNone
  okLog "nuikit: panel \"" & name & "\" built -- handle 0x" &
        hexOf(uint64(hnd)) & ", Image=0x" & hexOf(cast[uint64](img)) &
        ", " & $int(cNkLiveCount()) & " of " & $int(cNkCapacity()) &
        " handles live"
  result = NuElem(hnd)

proc nuLabel*(parentGo, donorTmp: Il2CppPtr; x, y, w, h: float32;
              text: string; fontSize: float32 = 22.0'f32;
              r: float32 = 1.0'f32; g: float32 = 1.0'f32;
              b: float32 = 1.0'f32; a: float32 = 1.0'f32;
              name: string = "aowl-label"): NuElem =
  ## A from-scratch `TextMeshProUGUI`. `donorTmp` is a LIVE TMP whose font asset
  ## and materials are copied in while the object is inactive -- without them
  ## TMP's Awake reaches for the default font through TMP_Settings and faults,
  ## so a missing donor is a REFUSAL here, not a best-effort.
  ##
  ## The text is applied TWICE, deliberately: `LocalizedText` can clobber a raw
  ## `m_text` store after ours, so the real setter is re-applied. Do not
  ## "simplify" that away.
  result = nuNone
  if not nkReady("label(\"" & name & "\")"): return nuNone
  if not nuOk(parentGo, 0x10'i32) or not nuAlive(parentGo):
    nkRefuse("label(\"" & name & "\")", "the parent is null, unreadable or a " &
             "destroyed Unity object")
    return nuNone
  if not nuOk(donorTmp, 0x10'i32) or not nuAlive(donorTmp):
    nkRefuse("label(\"" & name & "\")", "no live donor TMP. A from-scratch " &
             "TextMeshProUGUI with a null m_fontAsset faults in Awake, so " &
             "there is nothing safe to build without one")
    return nuNone
  discard nuRegisterReference(NuKindTmpText, donorTmp)

  let go = nuCreate(name, parentGo)
  if go == nil:
    nkRefuse("label(\"" & name & "\")", "the GameObject could not be created")
    return nuNone
  let rt = nuAdd(go, NuKindRectTransform)
  if rt == nil:
    nkRefuse("label(\"" & name & "\")", "AddComponent<RectTransform> yielded " &
             "nothing usable")
    discard nuDestroy(go); return nuNone
  if not nuParentAligned(go, parentGo):
    nkRefuse("label(\"" & name & "\")", "SetParentAndAlign failed")
    discard nuDestroy(go); return nuNone
  discard nuSetLayer(go, 5'i32)
  if not nuSetActive(go, false):
    nkRefuse("label(\"" & name & "\")", "could not deactivate before the TMP add")
    discard nuDestroy(go); return nuNone
  let tmp = nuAdd(go, NuKindTmpText)
  if tmp == nil:
    nkRefuse("label(\"" & name & "\")", "AddComponent<TextMeshProUGUI> yielded " &
             "nothing usable (slot state " &
             nuSlotStateName(cNuSlotState(NuKindTmpText)) & ")")
    discard nuDestroy(go); return nuNone
  if not nuWireTextDeps(tmp, donorTmp):
    nkRefuse("label(\"" & name & "\")", "the donor's font/material could not " &
             "be copied in; activating this TMP would fault in Awake")
    discard nuDestroy(go); return nuNone
  discard nuSetFontSize(tmp, fontSize)
  if not nuLayout(rt, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32,
                  w, h, x, y):
    nkRefuse("label(\"" & name & "\")", "layout refused this size/position")
    discard nuDestroy(go); return nuNone
  discard nuSetActive(go, true)
  discard nuSetText(tmp, text)
  discard nuSetText(tmp, text)               # re-apply after LocalizedText
  discard nuImgSetColor(tmp, r, g, b, a)     # TMP_Text IS a Graphic

  let hnd = cNkAlloc(go, rt, tmp, NkLabel)
  if hnd == 0'u32:
    nkRefuse("label(\"" & name & "\")", "the handle table is full (" &
             $int(cNkCapacity()) & " entries); destroying the element")
    discard nuDestroy(go); return nuNone
  okLog "nuikit: label \"" & name & "\" built -- handle 0x" &
        hexOf(uint64(hnd)) & ", TMP=0x" & hexOf(cast[uint64](tmp)) &
        ", " & $int(cNkLiveCount()) & " of " & $int(cNkCapacity()) &
        " handles live"
  result = NuElem(hnd)

# ---------------------------------------------------------------------------
# SETTERS. Every one of them: resolve the handle, check liveness, then one
# byte-verified setter call. No allocation except the interned string in
# `nuSetText`.
# ---------------------------------------------------------------------------
proc nuSetRect*(e: NuElem; x, y, w, h: float32): bool =
  if not nkReady("setRect"): return false
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "setRect", go, rt, comp, kind): return false
  result = nuLayout(rt, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32,
                    w, h, x, y)

proc nuSetColor*(e: NuElem; r, g, b, a: float32): bool =
  ## Works for both kinds: `TMP_Text` derives from `Graphic`, so one
  ## `Graphic::set_color` covers a panel's fill and a label's text colour.
  if not nkReady("setColor"): return false
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "setColor", go, rt, comp, kind): return false
  if not nuOk(comp, 0x40'i32):
    nkRefuse("setColor", "the Graphic component is not readable to +0x40, " &
             "where m_Color lives")
    return false
  result = nuImgSetColor(comp, r, g, b, a)

proc nuSetText*(e: NuElem; s: string): bool =
  if not nkReady("setText"): return false
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "setText", go, rt, comp, kind): return false
  if kind != NkLabel:
    nkRefuse("setText", "this handle is a " & nkKindName(kind) &
             ", which has no text. Refusing rather than writing 0x28 bytes " &
             "into an Image and hoping")
    return false
  result = nuSetText(comp, s)
  if result: discard nuSetText(comp, s)      # re-apply

proc nuSetActive*(e: NuElem; on: bool): bool =
  if not nkReady("setActive"): return false
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "setActive", go, rt, comp, kind): return false
  result = nuSetActive(go, on)

proc nuDestroy*(e: NuElem): bool =
  ## Destroy the element and SPEND the handle. Calling this twice is safe and
  ## says so: the second call resolves RELEASED and refuses.
  if not nkReady("destroy"): return false
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "destroy", go, rt, comp, kind): return false
  result = nuDestroy(go)
  discard cNkRelease(uint32(e))

proc nuDestroyAllElems*(): int =
  ## Tear down every element this toolkit still holds. Capped by construction.
  result = 0
  if not gNkOn: return 0
  let cap = int(cNkCapacity())
  for i in 0 ..< cap:
    let h = cNkAt(int32(i))
    if h == 0'u32: continue
    let go = cNkGo(h)
    if go != nil and nuOk(go, 0x10'i32) and nuAlive(go):
      if nuDestroy(go): inc result
    discard cNkRelease(h)
  gNkCanvasGo = nil
  okLog "nuikit: destroyAllElems destroyed " & $result & " element(s); every " &
        "handle issued before this call now refuses as RELEASED"

# ---------------------------------------------------------------------------
# READBACK -- what the self-test asserts against, and what a mod uses to check
# its own work. These read the FINISHED STATE from the live object.
# ---------------------------------------------------------------------------
proc nuElemRect*(e: NuElem): (bool, float32, float32, float32, float32) =
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "elemRect", go, rt, comp, kind):
    return (false, 0'f32, 0'f32, 0'f32, 0'f32)
  nuGetRect(rt)

proc nuElemColor*(e: NuElem): (bool, float32, float32, float32, float32) =
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "elemColor", go, rt, comp, kind):
    return (false, 0'f32, 0'f32, 0'f32, 0'f32)
  nuImgReadColor(comp)

proc nuElemText*(e: NuElem): string =
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "elemText", go, rt, comp, kind): return ""
  if kind != NkLabel: return ""
  nuGetText(comp)

proc nuElemActive*(e: NuElem): bool =
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "elemActive", go, rt, comp, kind): return false
  nuActiveInHierarchy(go)

# ===========================================================================
# THE SELF-TEST.  CLAUDE.md §9b, applied literally.
#
# It asserts the FINISHED STATE read back off the live objects -- never its own
# writes -- and it prefers the NEGATIVE where it can: after teardown, NO handle
# may still resolve. That is a check with an input that makes it fail (a handle
# table without generations passes the positive half and fails this).
#
# Three outcomes. INCONCLUSIVE is used, not avoided: if there is no canvas or no
# donor TMP, nothing was built and the toolkit has not been tested. "I could not
# look" is not a pass.
#
# WHAT A PASS DOES NOT MEAN. It does NOT mean a human sees pixels. It means the
# objects exist, are alive, are active in the hierarchy, sit under a live
# Canvas, and read back the geometry, colour and text they were given. A canvas
# hidden behind another, a zero scale factor, or a camera that does not render
# it are all still possible and none of them are visible from here.
# ===========================================================================
const NkTestPanelName = "aowlspt-nuikit-selftest-panel"
const NkTestLabelName = "aowlspt-nuikit-selftest-label"
const NkTestText      = "AOWLSPT NUIKIT SELFTEST"

var gNkVerdict = "not run"

proc nkNear(v, target, tol: float32): bool =
  (v - target) < tol and (target - v) < tol

proc nuKitSelfTestWanted(): bool = gNkOn and gNkProof and not gNkProofDone

proc nuKitSelfTestRun(tab: Il2CppPtr) =
  ## Rides invoke2's postfix drain, ALREADY inside one `aowl_p_p_seh`. Opens
  ## none of its own: nesting would disarm the outer guard.
  if not nuKitSelfTestWanted(): return
  gNkProofDone = true
  gNkVerdict = "INCONCLUSIVE"

  okLog "nuikit SELFTEST: BEGIN -- build one panel and one label through the " &
        "TOOLKIT (not the primitives), read back rect/colour/text/active from " &
        "the LIVE objects, destroy them, then assert the handles REFUSE."

  if not nkReady("selftest"):
    warn "nuikit SELFTEST: VERDICT = INCONCLUSIVE -- the toolkit is not " &
         "armed (nativeUi off, or a layer self-disabled). NOTHING was built, " &
         "so this says nothing about the toolkit."
    return

  # A live anchor: the same donor every other proof walks to.
  mi2FindTmp(tab)
  if gMi2Tmp == nil or gMi2TmpOwner == nil:
    warn "nuikit SELFTEST: VERDICT = INCONCLUSIVE -- no live donor TMP on this " &
         "tab, so there is no validated object to anchor the canvas walk on " &
         "and no font to build a label from. Nothing was created."
    return

  let canvasGo = nuFindCanvas(gMi2TmpOwner)
  let parentGo = (if canvasGo != nil: canvasGo else: nuGameObjectOf(gMi2TmpOwner))
  if parentGo == nil:
    warn "nuikit SELFTEST: VERDICT = INCONCLUSIVE -- neither nuFindCanvas nor " &
         "the donor's own GameObject gave a live parent. Nothing was created."
    return
  if canvasGo == nil:
    okLog "nuikit SELFTEST: nuFindCanvas found nothing usable, so this run " &
          "parents into the DONOR's GameObject instead. That still exercises " &
          "the constructors and the handle table, but it does NOT test canvas " &
          "discovery -- that part of the run is INCONCLUSIVE whatever the " &
          "final verdict says."

  # ---------------------------------------------------------------- build
  let panel = nuPanel(parentGo, 320.0'f32, -300.0'f32, 260.0'f32, 90.0'f32,
                      0.10'f32, 0.55'f32, 0.95'f32, 0.85'f32, NkTestPanelName)
  if uint32(panel) == 0'u32:
    warn "nuikit SELFTEST: VERDICT = FAIL -- nuPanel refused; the reason is " &
         "the `nuikit: panel(...) REFUSED` line above."
    gNkVerdict = "FAIL"
    return

  let label = nuLabel(parentGo, gMi2Tmp, 330.0'f32, -320.0'f32,
                      240.0'f32, 40.0'f32, NkTestText, 22.0'f32,
                      1.0'f32, 1.0'f32, 1.0'f32, 1.0'f32, NkTestLabelName)
  if uint32(label) == 0'u32:
    warn "nuikit SELFTEST: VERDICT = FAIL -- the panel was built but nuLabel " &
         "refused; tearing the panel down."
    discard nuDestroy(panel)
    gNkVerdict = "FAIL"
    return

  # ------------------------------------------------- read the FINISHED state
  let (rectOk, _, _, pw, ph) = nuElemRect(panel)
  let (colOk, cr, cg, cb, ca) = nuElemColor(panel)
  let panelActive = nuElemActive(panel)
  let (lrectOk, _, _, lw, lh) = nuElemRect(label)
  let labelText = nuElemText(label)
  let labelActive = nuElemActive(label)

  let panelSized = rectOk and nkNear(pw, 260.0'f32, 1.0'f32) and
                   nkNear(ph, 90.0'f32, 1.0'f32) and
                   cNuRectRenderable(pw, ph) != 0'i32
  # The colour is read RAW at m_Color+0x28, not through get_color: reading back
  # through the property that wrote it would be a self-comparison.
  let panelColoured = colOk and ca > 0.5'f32 and cb > 0.9'f32 and
                      cr < 0.3'f32 and cg > 0.4'f32 and cg < 0.7'f32
  let labelSized = lrectOk and cNuRectRenderable(lw, lh) != 0'i32
  let textTook = labelText == NkTestText

  okLog "nuikit SELFTEST: panel readback -- rect=(" & nuF(pw) & "x" & nuF(ph) &
        ") sizedAsAsked=" & $panelSized & "  m_Color@0x28 raw=(" &
        (if colOk: nuF(cr) & ", " & nuF(cg) & ", " & nuF(cb) & ", " & nuF(ca)
         else: "UNREADABLE") & ") matchesWhatWasAskedFor=" & $panelColoured &
        "  activeInHierarchy=" & $panelActive
  okLog "nuikit SELFTEST: label readback -- rect=(" & nuF(lw) & "x" & nuF(lh) &
        ") renderable=" & $labelSized & "  get_text round-trip=\"" & labelText &
        "\" matchesWhatWasAskedFor=" & $textTook & "  activeInHierarchy=" &
        $labelActive

  # ------------------------------------------------- exercise the setters
  let reRect = nuSetRect(panel, 320.0'f32, -300.0'f32, 300.0'f32, 100.0'f32)
  let (rr2, _, _, pw2, ph2) = nuElemRect(panel)
  let reSized = reRect and rr2 and nkNear(pw2, 300.0'f32, 1.0'f32) and
                nkNear(ph2, 100.0'f32, 1.0'f32)
  let reText = nuSetText(label, NkTestText & " OK")
  let textBack = nuElemText(label)
  let reTextTook = reText and textBack == (NkTestText & " OK")
  # A panel has no text. The toolkit must REFUSE, not write into an Image.
  let wrongKindRefused = not nuSetText(panel, "this must not be accepted")
  okLog "nuikit SELFTEST: setters -- setRect readback=(" & nuF(pw2) & "x" &
        nuF(ph2) & ") took=" & $reSized & "; setText readback=\"" & textBack &
        "\" took=" & $reTextTook & "; setText on a PANEL refused=" &
        $wrongKindRefused & " (that refusal is the point: a kind check that " &
        "accepts everything is a check that cannot fail)"

  # ------------------------------------------------- teardown, then the NEGATIVE
  let stalePanel = panel
  let staleLabel = label
  let destroyedP = nuDestroy(panel)
  let destroyedL = nuDestroy(label)
  # THE ASSERTION THIS WHOLE FILE EXISTS FOR. After teardown NO operation on a
  # spent handle may succeed. A bare-index handle table passes everything above
  # and fails right here.
  let refusesResolve = not nuValidHandle(stalePanel) and
                       not nuValidHandle(staleLabel)
  let refusesLive    = not nuLive(stalePanel) and not nuLive(staleLabel)
  let refusesSetRect = not nuSetRect(stalePanel, 0'f32, 0'f32, 10'f32, 10'f32)
  let refusesSetText = not nuSetText(staleLabel, "must not be accepted")
  let refusesDestroy = not nuDestroy(stalePanel)
  let refusesAll = refusesResolve and refusesLive and refusesSetRect and
                   refusesSetText and refusesDestroy
  okLog "nuikit SELFTEST: after teardown (panel destroyed=" & $destroyedP &
        ", label destroyed=" & $destroyedL & ") the SPENT handles refuse -- " &
        "resolve=" & $refusesResolve & " live=" & $refusesLive & " setRect=" &
        $refusesSetRect & " setText=" & $refusesSetText & " destroy=" &
        $refusesDestroy & "; live handles now " & $int(cNkLiveCount())
  let tableDrained = int(cNkLiveCount()) == 0

  # ------------------------------------------------------------- the verdict
  if not rectOk or not colOk or not lrectOk:
    gNkVerdict = "INCONCLUSIVE"
    warn "nuikit SELFTEST: VERDICT = INCONCLUSIVE -- a required readback " &
         "could not be performed (panel rect ok=" & $rectOk & ", panel colour " &
         "ok=" & $colOk & ", label rect ok=" & $lrectOk & "). The elements " &
         "were built and torn down, but the finished state could not be " &
         "examined, so this is not a pass."
  elif panelSized and panelColoured and panelActive and labelSized and
       textTook and labelActive and reSized and reTextTook and
       wrongKindRefused and refusesAll and tableDrained:
    gNkVerdict = "PASS"
    okLog "nuikit SELFTEST: VERDICT = PASS -- a panel and a label were built " &
          "FROM SCRATCH through the toolkit, each read back the geometry, " &
          "colour and text it was given, both were active in the hierarchy, " &
          "both were destroyed, and every spent handle now REFUSES with a " &
          "named reason. PASS DOES NOT PROVE A HUMAN SEES PIXELS: it proves " &
          "the objects existed, were live, and answered correctly. A canvas " &
          "behind another canvas, a zero scale factor, or a camera that does " &
          "not render it are all still possible and invisible from here."
  else:
    gNkVerdict = "FAIL"
    warn "nuikit SELFTEST: VERDICT = FAIL -- " &
         (if not panelSized: "the panel's rect did not read back as asked. "
          else: "") &
         (if not panelColoured: "m_Color did not read back as asked. " else: "") &
         (if not panelActive: "the panel was not activeInHierarchy. " else: "") &
         (if not labelSized: "the label's rect is not renderable. " else: "") &
         (if not textTook: "get_text did not round-trip. " else: "") &
         (if not labelActive: "the label was not activeInHierarchy. " else: "") &
         (if not reSized: "setRect did not take. " else: "") &
         (if not reTextTook: "setText did not take. " else: "") &
         (if not wrongKindRefused: "setText on a PANEL was ACCEPTED -- the " &
                                   "kind check is not doing anything. "
          else: "") &
         (if not refusesAll: "A SPENT HANDLE STILL WORKED. That is the " &
                             "generation counter failing, and it is the " &
                             "crash this toolkit exists to prevent. "
          else: "") &
         (if not tableDrained: "the handle table did not drain to zero. "
          else: "")

  okLog "nuikit SELFTEST: OVERALL = " & gNkVerdict & ". Canvas discovery was " &
        (if canvasGo != nil: "EXERCISED (the inspector's iSceneRoots walk)."
         else: "NOT exercised this run; it is INCONCLUSIVE independently of " &
               "the verdict above.")

proc bindNuiKit*(verbose: bool) =
  ## No detour of its own, by design -- the only proven Unity-thread point where
  ## a live screen and built controls both exist is already taken by invoke2's
  ## postfix on `SettingsScreen::EnsureTabInitialized`, and a second detour
  ## there would overwrite the first's trampoline and silently kill it. This
  ## rides that drain, exactly like `nuProofRun` and `auProofRun`.
  if not gNkOn: return
  if not gNuOn:
    warn "nuikit: `nativeUiKit` is on but `nativeUi` is OFF. The toolkit is a " &
         "facade over that layer and will refuse every call. Turn on nativeUi."
    return
  okLog "nuikit: the native-UI toolkit is ARMED -- nuPanel/nuLabel/nuSetRect/" &
        "nuSetColor/nuSetText/nuSetActive/nuDestroy over a " &
        $int(cNkCapacity()) & "-entry generation-checked handle table, and " &
        "nuFindCanvas (the LIVE INSPECTOR's scene-root walk, consumed -- not a " &
        "second implementation). Self-test is " &
        (if gNkProof: "ENABLED (nativeUiKitProof): open Settings and click a tab."
         else: "OFF (nativeUiKitProof).")
  if verbose:
    info "nuikit: handle layout is (generation << 16) | (index + 1); handle 0 " &
         "is never valid, and a freed slot keeps its generation so every " &
         "handle to it reads STALE rather than resolving to its successor."

# ---------------------------------------------------------------------------
# NuStyle -- MATCH THE GAME'S LOOK INSTEAD OF APPROXIMATING IT
#
# Every native panel this host builds has so far picked its own font size,
# colour and position out of the air, and the result reads as an overlay bolted
# onto the game rather than a part of it. The mod-loading screen was the first
# to be judged that way by a human, and the note was exact: it should match the
# position, font and size of the game's own "Loading profile data..." caption.
#
# That fix is worth having ONCE, here, rather than once per feature:
#
#   * the loading screen matches the loading caption,
#   * a settings row can match a stock settings row,
#   * the mods tab can match a stock tab,
#
# and none of them carries a hardcoded number that rots when BSG restyles.
#
# HOW IT MATCHES: the donor is found BY DISPLAYED TEXT, never by object name or
# a hardcoded path. Names change between builds and the captions are localized,
# but "the label that currently reads <something>" is what the player is
# actually looking at, and it is the thing we want to sit beside. The donor is
# then used for BOTH jobs -- `nuLabel` copies its font asset and materials, and
# this reads its size and position -- so the two can never disagree.
#
# WHAT IT REFUSES: a font size outside a sane range is treated as a MISREAD
# OFFSET, not as a font size. Laying a panel out from a garbage number is worse
# than using our own default, so `ok` goes false and `why` says so.

const
  NuStyleFontSizeOff* = 0x1ec'i32
    ## `TMPro.TMP_Text.m_fontSize`, float. Resolved offline against this build
    ## with `il2cpp_resolve.py fields TMPro.TMP_Text`; `m_text` sits at 0xe0 and
    ## `UnityEngine.UI.Graphic.m_Color` at 0x28 on the same object, which is how
    ## the offset was cross-checked rather than taken on its own.
  NuStyleMinFont* = 4.0'f32
  NuStyleMaxFont* = 200.0'f32
  NuStyleBudget* = 3000
    ## Nodes a style search may visit. Bounded like every other walk here: an
    ## unbounded descent on a scene full of geometry is how natesp's own walk
    ## burned 20,000 nodes and never reached any UI.

type
  NuStyle* = object
    ok*: bool            ## false means: use your own defaults, and say so
    why*: string         ## why it is not ok -- never silent
    donor*: Il2CppPtr    ## the live TMP: font + material donor for nuLabel
    node*: Il2CppPtr     ## its transform, for position
    text*: string        ## what it says right now (evidence, for the log)
    fontSize*: float32
    x*, y*: float32      ## its anchored position
    w*, h*: float32      ## its sizeDelta
    aMinX*, aMinY*: float32   ## its anchorMin
    aMaxX*, aMaxY*: float32   ## its anchorMax
    pivX*, pivY*: float32     ## its pivot
    geom*: bool          ## true when the four geometry reads above ALL landed
      ## WHY THE ANCHORS ARE PART OF THE STYLE. An `anchoredPosition` means
      ## nothing on its own: it is interpreted relative to the anchors and the
      ## pivot. Copying the donor's (x, y) onto an element anchored top-left,
      ## as the first version did, puts our text somewhere the donor is not --
      ## and it does it SILENTLY, producing a plausible number and a wrong
      ## position. So a style either carries the whole frame or admits it does
      ## not (`geom = false`), and a caller that reparents must check.

proc nuStyleCapture*(donorTmp, node: Il2CppPtr): NuStyle =
  ## Read a live TMP's look. Every read is guarded; nothing is assumed.
  result = NuStyle(ok: false, why: "", donor: donorTmp, node: node,
                   text: "", fontSize: 0.0'f32, x: 0.0'f32, y: 0.0'f32,
                   w: 0.0'f32, h: 0.0'f32,
                   aMinX: 0.0'f32, aMinY: 1.0'f32,
                   aMaxX: 0.0'f32, aMaxY: 1.0'f32,
                   pivX: 0.0'f32, pivY: 1.0'f32, geom: false)
  if donorTmp == nil:
    result.why = "no donor TMP"
    return
  if not nuOk(donorTmp, NuStyleFontSizeOff + 4'i32):
    result.why = "the donor is not readable as far as m_fontSize@0x" &
                 hexOf(uint64(NuStyleFontSizeOff))
    return
  let fs = float32(cReadF32(cast[Il2CppPtr](
    cast[uint64](donorTmp) + uint64(NuStyleFontSizeOff))))
  if not (fs > NuStyleMinFont and fs < NuStyleMaxFont):
    # A number outside this range is not a font size. It is a misread offset,
    # and a panel laid out from it would be silently wrong rather than visibly
    # broken -- which is the harder bug to find.
    result.why = "m_fontSize read back as " & nuF(fs) &
                 ", which is not a plausible font size; treating the offset " &
                 "as MISREAD rather than laying out from it"
    return
  result.fontSize = fs
  if node != nil:
    let (pok, nx, ny) = nuGetPos(node)
    if pok:
      result.x = nx
      result.y = ny
    # THE WHOLE FRAME, or none of it. Each of these is an Injected getter that
    # can decline; `geom` is the AND of all four, so a caller cannot pick up a
    # half-read frame and lay out from it.
    let (sok, sw, sh) = nuGetSize(node)
    let (nok, nax, nay) = nuGetV2(node, NuTRtGetAnchorMin)
    let (xok, xax, xay) = nuGetV2(node, NuTRtGetAnchorMax)
    let (vok, pvx, pvy) = nuGetV2(node, NuTRtGetPivot)
    if pok and sok and nok and xok and vok:
      result.w = sw; result.h = sh
      result.aMinX = nax; result.aMinY = nay
      result.aMaxX = xax; result.aMaxY = xay
      result.pivX = pvx; result.pivY = pvy
      result.geom = true
  result.ok = true

proc nuStyleFind*(rootTr: Il2CppPtr; needleLower: string;
                  rejectNameSub: string = ""): NuStyle =
  ## Find a live TMP whose DISPLAYED TEXT contains `needleLower` (already
  ## lower-case) and capture its style. Breadth-first and bounded: the label we
  ## want is shallow under a menu canvas, and a depth-first walk would spend the
  ## whole budget in the first large subtree it entered.
  ##
  ## `rejectNameSub` IS NOT OPTIONAL POLISH. MEASURED, live, 2026-09-01: the
  ## mod-loading step searched for the needle "loading", and the first TMP it
  ## found displaying "loading" was ITS OWN first line, which reads
  ## "Loading mods: graphics". It then adopted its own font and position and
  ## logged `MATCHED the game's own label "Loading mods: graphics"` followed by
  ## `style check PASSED`.
  ##
  ## Both statements were false and NEITHER could ever have been false: a
  ## search that can return the caller's own node turns "does our text match
  ## the game's" into "does our text match our text", which is precisely the
  ## check-that-cannot-fail shape of CLAUDE.md 9b. The user's verdict on the
  ## result -- "the text formatting/look still SUCKS" -- was the only honest
  ## signal in the loop.
  ##
  ## So a caller that creates TMPs MUST pass the substring its own objects are
  ## named with. A hit on such a node is not a weaker match, it is NOT A MATCH,
  ## and `why` says so by name so the log cannot be misread as "the game has no
  ## caption".
  ##
  ## The name is read ONLY on a needle hit, never per node, so this costs a
  ## handful of `Object::get_name` calls rather than one per walked node.
  result = NuStyle(ok: false, why: "no TMP under this root displays \"" &
                   needleLower & "\"", donor: nil, node: nil, text: "",
                   fontSize: 0.0'f32, x: 0.0'f32, y: 0.0'f32)
  if rootTr == nil:
    result.why = "no root to search from"
    return
  var budget = NuStyleBudget
  var mine = 0                 ## needle hits that turned out to be OUR OWN
  var mineText = ""
  var frontier: seq[Il2CppPtr] = @[rootTr]
  while frontier.len > 0 and budget > 0:
    var nextRow: seq[Il2CppPtr] = @[]
    for node in frontier:
      if budget <= 0: break
      dec budget
      let tmp = splTmpOf(node)
      if tmp != nil:
        let t = splTmpText(tmp)
        if t.len > 0 and find(toLowerAscii(t), needleLower) >= 0:
          var ours = false
          if rejectNameSub.len > 0:
            let nm = iObjName(node)
            if nm.len > 0 and find(nm, rejectNameSub) >= 0:
              ours = true
          if not ours:
            result = nuStyleCapture(tmp, node)
            result.text = t
            return result
          inc mine
          if mineText.len == 0: mineText = t
      var n = 0
      if iChildCount(node, n):
        for i in 0 ..< n:
          if nextRow.len >= budget: break
          let c = iChildAt(node, i)
          if c != nil: nextRow.add c
    frontier = nextRow
  if mine > 0:
    result.why = "the only TMP(s) displaying \"" & needleLower & "\" under " &
                 "this root are OURS -- " & $mine & " node(s) named \"" &
                 rejectNameSub & "*\", the first reading \"" & mineText &
                 "\". Matching our own text against itself would be a check " &
                 "that cannot fail, so this is NOT a match. It also means the " &
                 "game's own caption is not present right now"

proc nuStyleNote*(s: NuStyle): string =
  ## One line for the log, saying what was matched or why nothing was.
  if s.ok:
    result = "MATCHED the game's own label \"" & s.text & "\" (font " &
             nuF(s.fontSize) & " at " & nuF(s.x) & ", " & nuF(s.y) &
             ", frame " & (if s.geom: "READ" else: "NOT read -- position " &
             "cannot be copied") & ")"
  else:
    result = "NOT matched (" & s.why & "); using our own defaults"
  # SAY THE LIMIT OUT LOUD, on both branches. The donor is found by DISPLAYED
  # TEXT, and displayed text is LOCALIZED: an English needle finds nothing on
  # a Russian client, and the honest reading of "NOT matched" there is "we
  # looked for the wrong word", not "the game has no caption". Until the match
  # is structural, the log must not let that be mistaken for a scene fact.
  result = result & " [matched by DISPLAYED TEXT, which is LOCALIZED -- a " &
           "non-English client will not match this needle]"

# ---------------------------------------------------------------------------
# APPLYING a captured style to an element we already built, and READING BACK
# what actually landed.
#
# Both halves exist for the same reason. A style match is not available at the
# moment a panel is built -- the game's own caption is TRANSIENT, it exists
# only while the load runs -- so the match has to be retried on later frames
# and applied to elements that are already on screen. And per CLAUDE.md 9b,
# "we called the setter" is not evidence: `nuElemFontSize` reads the number
# back off the live TMP so a caller can compare it against the DONOR's, which
# is a comparison that can fail.
# ---------------------------------------------------------------------------
proc nuStyleLayout*(e: NuElem; s: NuStyle; dx, dy: float32;
                    wScale: float32 = 1.0'f32): bool =
  ## Lay `e` out in the donor's own frame -- its anchors, its pivot, its height
  ## -- offset by (dx, dy) from the donor's anchoredPosition. That is what
  ## "directly under the game's caption" has to mean once the two can sit under
  ## different parents with different anchors.
  ##
  ## REFUSES unless `s.geom` -- see the note on NuStyle. Laying out from a
  ## position whose anchors were never read is the silent-wrong-place bug this
  ## whole field set was added to prevent.
  if not nkReady("styleLayout"): return false
  if not s.ok or not s.geom:
    nkRefuse("styleLayout", "this NuStyle has no complete geometry (ok=" &
             $s.ok & " geom=" & $s.geom & "), so there is no donor frame to " &
             "lay out in. Refusing rather than inventing anchors")
    return false
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "styleLayout", go, rt, comp, kind): return false
  result = nuLayout(rt, s.aMinX, s.aMinY, s.aMaxX, s.aMaxY, s.pivX, s.pivY,
                    s.w * wScale, s.h, s.x + dx, s.y + dy)

proc nuStyleFont*(e: NuElem; s: NuStyle): bool =
  ## Give an existing label the donor's font SIZE. The font ASSET and materials
  ## came from the same donor at `nuLabel` time, so the two cannot disagree.
  if not nkReady("styleFont"): return false
  if not s.ok: return false
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "styleFont", go, rt, comp, kind): return false
  if kind != NkLabel:
    nkRefuse("styleFont", "this handle is a " & nkKindName(kind) &
             ", which has no font size")
    return false
  result = nuSetFontSize(comp, s.fontSize)

proc nuElemFontSize*(e: NuElem): (bool, float32) =
  ## READBACK: what m_fontSize says on the live TMP right now. Not what we set.
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "elemFontSize", go, rt, comp, kind):
    return (false, 0.0'f32)
  if kind != NkLabel: return (false, 0.0'f32)
  if not nuOk(comp, NuStyleFontSizeOff + 4'i32): return (false, 0.0'f32)
  (true, float32(cReadF32(cast[Il2CppPtr](
     cast[uint64](comp) + uint64(NuStyleFontSizeOff)))))

proc nuReparent*(e: NuElem; parentGo: Il2CppPtr): bool =
  ## Move an EXISTING element under a new parent, aligned.
  ##
  ## This exists because the match that matters arrives LATE. The game's own
  ## loading caption does not exist when the mod-loading step first builds, so
  ## the step is created under the canvas and only later learns which container
  ## it should have belonged to. Without this the log had to say "position
  ## matched; NOT reparented", which is a real limitation reported honestly and
  ## still a limitation.
  ##
  ## `SetParentAndAlign` resets the local transform, so the CALLER MUST re-lay
  ## out afterwards -- `nuStyleLayout` in the donor's frame is the intended
  ## follow-up. Reparenting without that leaves the element at the new parent's
  ## origin, which is a visible move to the wrong place, not a no-op.
  if not nkReady("reparent"): return false
  if not nuOk(parentGo, 0x10'i32) or not nuAlive(parentGo):
    nkRefuse("reparent", "the new parent is null, unreadable or a destroyed " &
             "Unity object; leaving the element where it is")
    return false
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "reparent", go, rt, comp, kind): return false
  result = nuParentAligned(go, parentGo)
  if not result:
    nkRefuse("reparent", "SetParentAndAlign refused; the element is still " &
             "under its original parent and its layout is untouched")
