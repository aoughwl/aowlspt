## ===========================================================================
## invui -- THE NATIVE INVENTORY / ITEM-SPAWNER SCREEN
##
## Two columns of real Unity UI: OUR STASH on the left, a SEARCHABLE EVERYTHING
## list on the right, and a button that mints the selected right-hand row into
## the left one. It replaces a one-line text field in the D3D11 F6 HUD.
##
## ## Built from primitives. Not cloned.
##
## Every element here is `nuPanel` / `nuLabel` -- the ordering proven live on
## 2026-08-30 (IMAGEPROOF VERDICT = PASS). Nothing is cloned from a game
## prefab, and that is a decision, not laziness:
##
##   * There is no two-column inventory widget on this build that could be
##     cloned into the menu scene anyway -- the real one is built by the
##     inventory screen's own controller from bundle assets it owns.
##   * Cloning has a specific, measured failure mode here. A settings tab
##     caption lives in THREE TMPs; writing only `SizeLabel` sets `m_text`,
##     PASSES a read-back, and still renders the donor's text. A clone inherits
##     structure you did not author and therefore did not enumerate.
##
## The one thing that IS borrowed is a DONOR TMP -- a live `TextMeshProUGUI`
## whose font asset and materials `nuLabel` copies in. That is not a clone: the
## object is read, never written, and never reparented. A from-scratch TMP with
## a null `m_fontAsset` faults in Awake, so the donor is a hard precondition and
## its absence is a REFUSAL, not a best-effort label.
##
## ## Where the data comes from
##
## Nowhere in this process. Item minting is SERVER-side: `mods/tarkov` owns the
## profile and provides `aowl.items`, and `capability.invoke` REFUSES on
## `sideClient` by design. So this screen is a pure VIEW over
## `abi/aowlspt_invui.h`, a named shared-memory region the backend's copy of
## `mods/admin` drains. This file:
##
##   * writes a query and bumps a request;
##   * reads back rows when the ack catches up;
##   * asks for a mint and reads back the backend's PROFILE MEASUREMENT.
##
## It performs no spawn of its own and contains no item database. That is the
## point: there is exactly one minting path in this project and this screen
## calls it rather than becoming a second one.
##
## ## Where the TYPED TEXT comes from -- and the honest limit of this pass
##
## From the F6 overlay's WndProc, through `AowlAdminShared.spawnQuery`, which
## already captures printable keystrokes and is already a shipped, working
## feature. This screen MIRRORS that buffer and re-asks when it changes.
##
## That means, plainly: **the search bar is typed into through the F6 menu, not
## by clicking this panel and typing.** A native focus/caret/IME text field
## needs per-frame key scanning through `Input::GetKeyDown` over the whole
## KeyCode table and a caret model, and none of that is demonstrated on this
## build. Reusing the proven capture is worth more than a second, unproven one.
## The panel says so on screen, in the hint line, rather than looking like a
## text field that ignores clicks.
##
## ## What is NOT here, stated rather than implied
##
##   * **Drag and drop.** Out of reach this pass and deliberately not faked. It
##     needs a drag proxy element reparented to the canvas root each frame, a
##     drop-target hit test across two scrolling viewports, and a cancel path
##     for a drag released over nothing. A working click-to-select plus a mint
##     button beats a drag that drops items into the void. The click path is
##     the same selection model a drag would need, so this is a foundation for
##     it and not a detour around it.
##   * **Item icons.** They live in asset bundles; loading one and binding it to
##     a `Sprite` is unproven on this build. A row is a coloured plate and a
##     name, which is legible and honest.
##   * **Scrolling.** The columns show a fixed page of `cIuRows`. The row count
##     the backend really matched is displayed BESIDE the page, so a truncated
##     list is never presented as a complete one.
##
## ## THE EIGHT RULES
##
##   1. Prologue byte-verify -- every game call goes through `nuFn`, which
##      verifies against the STARTUP SNAPSHOT (`abi/aowlspt_prologue.h`), never
##      live memory. Plus `nuTargetsBindOk`, the positional check on the
##      index-addressed target table.
##   2. Every pointer hop validated -- `nuOk` + `nuAlive`, and `nkResolve` on
##      every handle, which additionally catches RELEASED and STALE-GENERATION.
##      Unity fake-null is why liveness is asked separately from readability.
##   3. ONE `aowl_p_p_seh`, opened by `aowl_iu_tick_guarded` around the whole
##      tick. This file opens NO guard of its own: the guard is not re-entrant
##      and a nested inner guard DISARMS the outer one.
##   4. Capped iteration everywhere -- `cIuRows` rows per column, `cIuDonorScan`
##      nodes in the donor walk, `cIuDonorDepth` levels. No walk of any game
##      collection is unbounded.
##   5. Flag-gated, DEFAULT OFF -- `nativeInvUi`.
##   6. Self-disables after `AOWL_IU_MAX_FAULTS` guarded faults.
##   7. No per-frame managed allocation. The panel is built ONCE. Row text is
##      rewritten only when the string CHANGES, through `nuSetText` -> `nuStr`,
##      which interns.
##   8. Never blind-write. An unreadable region, an incompatible region, a
##      missing donor and an unmapped canvas are each REFUSED by name.
##
## ## What this file may not claim
##
## That an item was spawned. It cannot see a profile. `iuVerdict` reports what
## the BACKEND MEASURED -- the count of the minted template in the profile
## before and after -- and reports INCONCLUSIVE, out loud, for every state in
## which nothing was examined: flag off, region unmapped, panel never built, no
## mint ever attempted. "I could not look" is not a pass.
## ===========================================================================

{.emit: """
/* Both regions. `aowlspt_admin.h` has an include guard and is already pulled in
 * by `region.nim` in this same translation unit; naming it here as well is what
 * makes this file's dependency explicit instead of inherited by luck. */
#include "aowlspt_admin.h"
#include "aowlspt_invui.h"

extern void* aowl_iu_tick_body(void* a);
static void* aowl_iu_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_iu_tick_body, a);
}

/* SELF-DISABLE. Six, for the same reason colorwidget uses six: enough to tell
 * "one bad frame during a scene change" from "this faults every frame forever",
 * small enough that the second case costs the player six frames and not the
 * session. */
#define AOWL_IU_MAX_FAULTS 6
static int32_t g_aowl_iu_faults = 0;
static int32_t aowl_iu_fault_count(void) { return g_aowl_iu_faults; }
static void    aowl_iu_note_fault(void)  { if (g_aowl_iu_faults < 1000) g_aowl_iu_faults++; }
static int32_t aowl_iu_disabled(void)    { return g_aowl_iu_faults >= AOWL_IU_MAX_FAULTS ? 1 : 0; }
static int32_t aowl_iu_max_faults(void)  { return AOWL_IU_MAX_FAULTS; }

/* The host's own view of the region. Mapped once, leaked on purpose (it lives
 * for the process), and NEVER created eagerly: `aowl_invui_map` creates the
 * section if it does not exist, which is correct -- whichever side starts
 * first creates it and stamps the magic. */
static AowlInvUiShared* g_aowl_iu_region = 0;
static AowlInvUiShared* aowl_iu_region(void) {
    if (!g_aowl_iu_region) g_aowl_iu_region = aowl_invui_map();
    return g_aowl_iu_region;
}

/* Character-at accessors, mirroring `adm/invui.nim`'s. Same reason: nimony has
 * no clean `cstring` out-buffer idiom and `adm/shared.nim` established this
 * pattern for `spawnQuery`. Every one CLAMPS against the region's own capacity
 * and stops at the first NUL. */
static int32_t aowl_iu_row_char(const char* buf, int32_t cap, int32_t i) {
    if (!buf || i < 0 || i >= cap) return 0;
    return (int32_t)(unsigned char)buf[i];
}
static int32_t aowl_iu_stash_name_at(int32_t row, int32_t i) {
    AowlInvUiShared* s = aowl_iu_region();
    if (row < 0 || row >= aowl_invui_stash_count(s)) return 0;
    return aowl_iu_row_char(s->stash[row].name, AOWL_IU_NAME_LEN, i);
}
static int32_t aowl_iu_stash_tpl_at(int32_t row, int32_t i) {
    AowlInvUiShared* s = aowl_iu_region();
    if (row < 0 || row >= aowl_invui_stash_count(s)) return 0;
    return aowl_iu_row_char(s->stash[row].tpl, AOWL_IU_TPL_LEN, i);
}
static int32_t aowl_iu_inv_name_at(int32_t row, int32_t i) {
    AowlInvUiShared* s = aowl_iu_region();
    if (row < 0 || row >= aowl_invui_inv_count(s)) return 0;
    return aowl_iu_row_char(s->inv[row].name, AOWL_IU_NAME_LEN, i);
}
static int32_t aowl_iu_note_at(int32_t i) {
    AowlInvUiShared* s = aowl_iu_region();
    if (!aowl_invui_compatible(s)) return 0;
    return aowl_iu_row_char(s->note, AOWL_IU_NOTE_LEN, i);
}

/* The ADMIN region's typed query -- the shipped F6 keystroke capture, reused.
 * Read-only from here: this screen never writes the admin region, so it cannot
 * disturb the F6 spawner it is borrowing the keyboard from. */
static AowlAdminShared* g_aowl_iu_admin = 0;
static AowlAdminShared* aowl_iu_admin(void) {
    if (!g_aowl_iu_admin) g_aowl_iu_admin = aowl_admin_map();
    return g_aowl_iu_admin;
}
static int32_t aowl_iu_admin_query_at(int32_t i) {
    AowlAdminShared* a = aowl_iu_admin();
    if (!a || i < 0 || i >= AOWL_ADM_QUERY_LEN) return 0;
    return (int32_t)(unsigned char)a->spawnQuery[i];
}
static int32_t aowl_iu_admin_query_cap(void) { return AOWL_ADM_QUERY_LEN; }
static int32_t aowl_iu_admin_menu_open(void) {
    AowlAdminShared* a = aowl_iu_admin();
    return aowl_admin_menu_open(a);
}

/* Thin forwards, so nimony never holds the region pointer itself. Holding it
 * would mean nimony deciding when it is valid; here there is exactly one
 * answer to that and it is in C. */
static int32_t aowl_iu_compatible_x(void)     { return aowl_invui_compatible(aowl_iu_region()); }
static int32_t aowl_iu_stash_count_x(void)    { return aowl_invui_stash_count(aowl_iu_region()); }
static int32_t aowl_iu_stash_matched_x(void)  { return aowl_invui_stash_matched(aowl_iu_region()); }
static int32_t aowl_iu_inv_count_x(void)      { return aowl_invui_inv_count(aowl_iu_region()); }
static int32_t aowl_iu_inv_total_x(void)      { return aowl_invui_inv_total(aowl_iu_region()); }
static int32_t aowl_iu_inv_qty_x(int32_t i)   { return aowl_invui_inv_qty(aowl_iu_region(), i); }
static int32_t aowl_iu_stash_ready_x(void)    { return aowl_invui_stash_ready(aowl_iu_region()); }
static int32_t aowl_iu_inv_ready_x(void)      { return aowl_invui_inv_ready(aowl_iu_region()); }
static int32_t aowl_iu_mint_busy_x(void)      { return aowl_invui_mint_busy(aowl_iu_region()); }
static int32_t aowl_iu_verdict_x(void)        { return aowl_invui_verdict(aowl_iu_region()); }
static int32_t aowl_iu_mint_before_x(void)    { return aowl_invui_mint_before(aowl_iu_region()); }
static int32_t aowl_iu_mint_after_x(void)     { return aowl_invui_mint_after(aowl_iu_region()); }
static int32_t aowl_iu_heartbeat_x(void)      { return aowl_invui_heartbeat(aowl_iu_region()); }
static int32_t aowl_iu_max_rows_x(void)       { return AOWL_IU_MAX_ROWS; }
static int32_t aowl_iu_name_cap_x(void)       { return AOWL_IU_NAME_LEN; }
static int32_t aowl_iu_tpl_cap_x(void)        { return AOWL_IU_TPL_LEN; }
static int32_t aowl_iu_note_cap_x(void)       { return AOWL_IU_NOTE_LEN; }

static int32_t aowl_iu_ask_stash_x(const char* q) {
    return aowl_invui_ask_stash(aowl_iu_region(), q);
}
static int32_t aowl_iu_ask_inv_x(void) {
    return aowl_invui_ask_inv(aowl_iu_region());
}
static int32_t aowl_iu_ask_mint_x(const char* tpl, int32_t n, int32_t cond) {
    return aowl_invui_ask_mint(aowl_iu_region(), tpl, n, cond);
}
""".}

proc cIuTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_iu_tick_guarded", nodecl.}
proc cIuNoteFault() {.importc: "aowl_iu_note_fault", nodecl.}
proc cIuFaultCount(): int32 {.importc: "aowl_iu_fault_count", nodecl.}
proc cIuDisabled(): int32 {.importc: "aowl_iu_disabled", nodecl.}
proc cIuMaxFaults(): int32 {.importc: "aowl_iu_max_faults", nodecl.}

proc cIuCompatible(): int32 {.importc: "aowl_iu_compatible_x", nodecl.}
proc cIuStashCount(): int32 {.importc: "aowl_iu_stash_count_x", nodecl.}
proc cIuStashMatched(): int32 {.importc: "aowl_iu_stash_matched_x", nodecl.}
proc cIuInvCount(): int32 {.importc: "aowl_iu_inv_count_x", nodecl.}
proc cIuInvTotal(): int32 {.importc: "aowl_iu_inv_total_x", nodecl.}
proc cIuInvQty(i: int32): int32 {.importc: "aowl_iu_inv_qty_x", nodecl.}
proc cIuStashReady(): int32 {.importc: "aowl_iu_stash_ready_x", nodecl.}
proc cIuInvReady(): int32 {.importc: "aowl_iu_inv_ready_x", nodecl.}
proc cIuMintBusy(): int32 {.importc: "aowl_iu_mint_busy_x", nodecl.}
proc cIuVerdict(): int32 {.importc: "aowl_iu_verdict_x", nodecl.}
proc cIuMintBefore(): int32 {.importc: "aowl_iu_mint_before_x", nodecl.}
proc cIuMintAfter(): int32 {.importc: "aowl_iu_mint_after_x", nodecl.}
proc cIuHeartbeat(): int32 {.importc: "aowl_iu_heartbeat_x", nodecl.}
proc cIuMaxRows(): int32 {.importc: "aowl_iu_max_rows_x", nodecl.}
proc cIuNameCap(): int32 {.importc: "aowl_iu_name_cap_x", nodecl.}
proc cIuTplCap(): int32 {.importc: "aowl_iu_tpl_cap_x", nodecl.}
proc cIuNoteCap(): int32 {.importc: "aowl_iu_note_cap_x", nodecl.}

proc cIuStashNameAt(row, i: int32): int32 {.
  importc: "aowl_iu_stash_name_at", nodecl.}
proc cIuStashTplAt(row, i: int32): int32 {.
  importc: "aowl_iu_stash_tpl_at", nodecl.}
proc cIuInvNameAt(row, i: int32): int32 {.
  importc: "aowl_iu_inv_name_at", nodecl.}
proc cIuNoteAt(i: int32): int32 {.importc: "aowl_iu_note_at", nodecl.}

proc cIuAdminQueryAt(i: int32): int32 {.
  importc: "aowl_iu_admin_query_at", nodecl.}
proc cIuAdminQueryCap(): int32 {.importc: "aowl_iu_admin_query_cap", nodecl.}
proc cIuAdminMenuOpen(): int32 {.importc: "aowl_iu_admin_menu_open", nodecl.}

proc cIuAskStash(q: cstring): int32 {.importc: "aowl_iu_ask_stash_x", nodecl.}
proc cIuAskInv(): int32 {.importc: "aowl_iu_ask_inv_x", nodecl.}
proc cIuAskMint(tpl: cstring; n, cond: int32): int32 {.
  importc: "aowl_iu_ask_mint_x", nodecl.}

# ---------------------------------------------------------------------------
# GEOMETRY. All in canvas-local space, top-left anchored with y NEGATIVE going
# down -- `nuPanel`'s documented convention and the one the IMAGEPROOF run used.
# The panel is CENTRED on the canvas at build time from the canvas's own
# measured rect, never from an assumed 1920x1080.
# ---------------------------------------------------------------------------
const
  cIuRows        = 14           ## rows per column. A CAP, not a target.
  cIuPanelW      = 1180.0'f32
  cIuPanelH      = 700.0'f32
  cIuPad         = 16.0'f32
  cIuTitleH      = 34.0'f32
  cIuSearchY     = -56.0'f32
  cIuSearchH     = 30.0'f32
  cIuHeaderY     = -98.0'f32
  cIuHeaderH     = 24.0'f32
  cIuListY       = -128.0'f32   ## first row's top edge
  cIuRowH        = 32.0'f32
  cIuRowGap      = 2.0'f32
  cIuColW        = 500.0'f32
  cIuLeftX       = 20.0'f32
  cIuRightX      = 660.0'f32
  cIuBtnW        = 120.0'f32
  cIuBtnH        = 40.0'f32
  cIuBtnX        = 530.0'f32
  cIuBtnY        = -300.0'f32
  cIuNoteY       = -600.0'f32
  cIuNoteH       = 44.0'f32
  cIuFontRow     = 17.0'f32
  cIuFontTitle   = 24.0'f32
  cIuFontNote    = 15.0'f32
  ## The donor walk's two caps. Both are bounds, not targets: the donor is
  ## normally found within the first dozen nodes of a menu canvas.
  cIuDonorScan   = 600
  cIuDonorDepth  = 8
  ## `UnityEngine.UI.Graphic.m_Canvas`, measured with tools/fldoff.py, whose
  ## mandatory `System.String._stringLength@0x10` self-check passed on the same
  ## run. Borrowed from `colorwidget.nim`, which measured it -- NOT re-guessed.
  cIuOffGraphicCanvas = 0x60'i32
  cIuOverlayMode      = 0'i32

# ---------------------------------------------------------------------------
# STATE. All of it allocated ONCE, at build.
# ---------------------------------------------------------------------------
type
  IuRowUi = object
    plate: NuElem      ## the clickable background
    label: NuElem
    lastText: string   ## what we last WROTE, so an unchanged row does not
                       ## re-enter nuSetText and re-intern a string
    tpl: string        ## the template id this row currently stands for
    tint: int32        ## the plate colour last WRITTEN, as a small enum
                       ## (0 idle, 1 selected, 2 empty). Tracked for the same
                       ## reason `lastText` is: without it every visible frame
                       ## re-entered `Graphic::set_color` on all 28 plates, which
                       ## allocates nothing but is 28 il2cpp calls a frame to
                       ## write the colour they already had.

var gIuOn = false                  ## the `nativeInvUi` flag
var gIuBuilt = false
var gIuBuildRefused = ""           ## why the build declined, if it did
var gIuVisible = false
var gIuArmed = false               ## the pointer mapping was validated
var gIuArmRefusalLogged = false
var gIuTicks = 0'i64
var gIuBackdrop = nuNone
var gIuTitle = nuNone
var gIuSearch = nuNone
var gIuSearchLbl = nuNone
var gIuHint = nuNone
var gIuHdrLeft = nuNone
var gIuHdrRight = nuNone
var gIuBtn = nuNone
var gIuBtnLbl = nuNone
var gIuNote = nuNone
var gIuLeft: seq[IuRowUi] = @[]
var gIuRight: seq[IuRowUi] = @[]

var gIuSel = -1                    ## selected RIGHT-hand row index, -1 = none
var gIuSelTpl = ""
var gIuLastQuery = ""
var gIuLastNote = ""
var gIuLastHdrL = ""
var gIuLastHdrR = ""
var gIuLastSearchTxt = ""
var gIuLastBtnTxt = ""
var gIuBtnTint = -1'i32            ## -1 = never written, so the first pass sets it
var gIuPrevDown = false            ## edge detection: act on press, not on hold
var gIuMintsAsked = 0
var gIuStashAsks = 0
var gIuInvAsks = 0
var gIuInvRefresh = 0'i64          ## tick at which to re-ask for the left column
var gIuLastVerdict = ""

# ---------------------------------------------------------------------------
# READING THE REGION. Every string comes out char by char, bounded by the
# region's OWN capacity and stopping at the first NUL, so a buffer written by
# something that is not our backend reads as a short string and never as a walk
# off the end of the section.
# ---------------------------------------------------------------------------
proc iuStashName(row: int): string =
  result = ""
  var i = 0'i32
  let cap = cIuNameCap()
  while i < cap:
    let c = cIuStashNameAt(int32(row), i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32

proc iuStashTpl(row: int): string =
  result = ""
  var i = 0'i32
  let cap = cIuTplCap()
  while i < cap:
    let c = cIuStashTplAt(int32(row), i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32

proc iuInvName(row: int): string =
  result = ""
  var i = 0'i32
  let cap = cIuNameCap()
  while i < cap:
    let c = cIuInvNameAt(int32(row), i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32

proc iuNoteText(): string =
  result = ""
  var i = 0'i32
  let cap = cIuNoteCap()
  while i < cap:
    let c = cIuNoteAt(i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32

proc iuTypedQuery(): string =
  ## The F6 overlay's captured keystrokes. Read-only: this screen never writes
  ## the admin region, so borrowing the keyboard cannot disturb the F6 spawner.
  result = ""
  var i = 0'i32
  let cap = cIuAdminQueryCap()
  while i < cap:
    let c = cIuAdminQueryAt(i)
    if c <= 0'i32 or c > 255'i32: break
    if c < 0x20'i32 or c > 0x7E'i32: break   # printable ASCII only, by contract
    result.add char(c)
    i = i + 1'i32

proc iuClip(s: string; n: int): string =
  ## Truncate for display. An ellipsis rather than a hard cut, so a clipped name
  ## is visibly clipped and cannot be mistaken for the whole name.
  if s.len <= n: s
  elif n <= 3: s.substr(0, n - 1)
  else: s.substr(0, n - 4) & "..."

# ---------------------------------------------------------------------------
# THE DONOR TMP. A breadth-first walk of the canvas subtree asking each node for
# a `TextMeshProUGUI`, capped in BOTH directions.
#
# `iVisComponent` returns COULD-WE-ASK, not presence, and this respects that: a
# node we could not ask is skipped and counted, never recorded as having no TMP.
# The distinction matters because "no donor exists" and "we could not look for
# one" produce the same empty result and only one of them is an absence.
# ---------------------------------------------------------------------------
proc iuFindDonorTmp(canvasTr: Il2CppPtr; scanned, unaskable: var int): Il2CppPtr =
  result = nil
  scanned = 0
  unaskable = 0
  if canvasTr == nil or not nuOk(canvasTr, 0x10'i32) or not nuAlive(canvasTr):
    return nil
  # An explicit queue with a depth tag. No recursion: a profile with a cycle in
  # its transform hierarchy would otherwise be a stack overflow inside the
  # guard, which the guard cannot save the frame from.
  var queue: seq[Il2CppPtr] = @[canvasTr]
  var depths: seq[int] = @[0]
  var head = 0
  while head < queue.len and scanned < cIuDonorScan:   # capped iteration
    let cur = queue[head]
    let d = depths[head]
    head = head + 1
    if cur == nil or not nuOk(cur, 0x10'i32) or not nuAlive(cur):
      continue
    scanned = scanned + 1
    var comp: Il2CppPtr = nil
    var why = ""
    if not iVisComponent(cur, "TextMeshProUGUI", comp, why):
      unaskable = unaskable + 1
    elif comp != nil and nuOk(comp, 0x60'i32) and nuAlive(comp):
      # +0x60 rather than +0x10: a donor is only useful if the fields `nuLabel`
      # copies out of it are readable, and refusing here is far cheaper than
      # refusing inside `nuWireTextDeps` after a GameObject has been created.
      return comp
    if d >= cIuDonorDepth:
      continue
    var n = 0
    if iChildCount(cur, n):
      var k = 0
      while k < n and queue.len < cIuDonorScan:        # capped both ways
        # `iChildAt` returns the child (or nil) rather than taking an out
        # parameter, and it returns nil for BOTH "no such child" and "the
        # receiver is a GameObject, not a Transform". Either way there is
        # nothing to queue, and the caps below bound the walk regardless.
        let child = iChildAt(cur, k)
        if child != nil:
          queue.add child
          depths.add d + 1
        k = k + 1
  nil

# ---------------------------------------------------------------------------
# BUILDING. Once. Every refusal is named and recorded in `gIuBuildRefused`, and
# a partial build is TORN DOWN rather than left on screen: half a panel is
# indistinguishable from a panel whose data never arrived.
# ---------------------------------------------------------------------------
proc iuRowY(i: int): float32 =
  cIuListY - float32(i) * (cIuRowH + cIuRowGap)

proc iuTeardown() =
  ## Destroy everything this screen owns, in reverse. Used by the failed-build
  ## path and by turning the flag off. Handles are cleared so a later tick
  ## cannot resolve a released slot -- which the generation counter would catch,
  ## but a refusal per element per frame is noise, not safety.
  for i in 0 ..< gIuLeft.len:
    discard nuDestroy(gIuLeft[i].label)
    discard nuDestroy(gIuLeft[i].plate)
  for i in 0 ..< gIuRight.len:
    discard nuDestroy(gIuRight[i].label)
    discard nuDestroy(gIuRight[i].plate)
  gIuLeft = @[]
  gIuRight = @[]
  discard nuDestroy(gIuNote);      gIuNote = nuNone
  discard nuDestroy(gIuBtnLbl);    gIuBtnLbl = nuNone
  discard nuDestroy(gIuBtn);       gIuBtn = nuNone
  discard nuDestroy(gIuHdrRight);  gIuHdrRight = nuNone
  discard nuDestroy(gIuHdrLeft);   gIuHdrLeft = nuNone
  discard nuDestroy(gIuHint);      gIuHint = nuNone
  discard nuDestroy(gIuSearchLbl); gIuSearchLbl = nuNone
  discard nuDestroy(gIuSearch);    gIuSearch = nuNone
  discard nuDestroy(gIuTitle);     gIuTitle = nuNone
  discard nuDestroy(gIuBackdrop);  gIuBackdrop = nuNone
  gIuBuilt = false
  gIuArmed = false
  gIuSel = -1
  gIuSelTpl = ""
  gIuLastQuery = ""
  gIuLastNote = ""

proc iuBuild(): bool =
  ## Build the whole screen, or build NONE of it.
  gIuBuildRefused = ""
  if cIuCompatible() == 0'i32:
    gIuBuildRefused = "the shared region " &
      "(Local\\aowlspt_invui_v1) is absent or its magic/version/row-stride " &
      "disagrees with this build. Nothing was created: a screen with no " &
      "backend is a screen that renders an empty stash as if the stash were " &
      "empty."
    return false
  if not nuTargetsBindOk():
    gIuBuildRefused = "the positional target table did not verify, so no call " &
      "into the game is safe from here"
    return false

  var pick = NuCanvasPick()
  if not nuCanvasFind(splAnchor(), 400.0'f32, pick):
    gIuBuildRefused = "no usable Canvas -- " & nuCanvasLedger(pick)
    return false
  let canvasGo = pick.go
  let canvasTr = pick.tr

  var scanned = 0
  var unaskable = 0
  let donor = iuFindDonorTmp(canvasTr, scanned, unaskable)
  if donor == nil:
    # THE THREE CAUSES, SEPARATED. "no donor" and "could not ask" are not the
    # same finding and a message that said "no donor found" for both would send
    # the next reader looking for a missing font asset when the real cause was
    # a GetComponent overload that did not resolve.
    gIuBuildRefused = "no live TextMeshProUGUI donor under the canvas after " &
      "scanning " & $scanned & " node(s) to depth " & $cIuDonorDepth &
      (if unaskable > 0:
         ", of which " & $unaskable & " could NOT BE ASKED (that is not an " &
         "absence -- GetComponent did not resolve or the icall is not " &
         "registered)"
       else:
         ", ALL of which were asked and none carried one") &
      ". A from-scratch TextMeshProUGUI with a null m_fontAsset faults in " &
      "Awake, so this is a REFUSAL, not a best-effort label."
    return false

  # Centre on the canvas's OWN measured rect. `pick.w`/`pick.h` were read back
  # through `nuGetRect`, not assumed -- a hard-coded 1920x1080 would put the
  # panel off screen on the 3840x2160 canvas this host has measured.
  let ox = (pick.w - cIuPanelW) * 0.5'f32
  let oy = -(pick.h - cIuPanelH) * 0.5'f32

  gIuBackdrop = nuPanel(canvasGo, ox, oy, cIuPanelW, cIuPanelH,
                        0.06'f32, 0.06'f32, 0.07'f32, 0.94'f32,
                        "aowlspt-invui-backdrop")
  if uint32(gIuBackdrop) == 0'u32:
    gIuBuildRefused = "the backdrop panel could not be created (nuikit logged " &
      "the reason above; a full handle table is the usual one)"
    iuTeardown()
    return false

  var bdGo: Il2CppPtr = nil
  var bdRt: Il2CppPtr = nil
  var bdComp: Il2CppPtr = nil
  var bdKind = 0'i32
  if not nkResolve(gIuBackdrop, "iuBuild", bdGo, bdRt, bdComp, bdKind):
    gIuBuildRefused = "the backdrop resolved to a handle that is not live"
    iuTeardown()
    return false

  # Everything else is parented to the BACKDROP, not to the canvas: one parent
  # means one thing to move, one thing to hide, and one thing to destroy. A
  # child left parented to the canvas would survive a teardown as an orphan
  # nobody has a handle to.
  gIuTitle = nuLabel(bdGo, donor, cIuPad, -cIuPad, cIuPanelW - cIuPad * 2.0'f32,
                     cIuTitleH, "AOWLSPT  --  ITEM SPAWNER", cIuFontTitle,
                     0.95'f32, 0.85'f32, 0.45'f32, 1.0'f32,
                     "aowlspt-invui-title")
  gIuSearch = nuPanel(bdGo, cIuPad, cIuSearchY,
                      cIuPanelW - cIuPad * 2.0'f32, cIuSearchH,
                      0.14'f32, 0.14'f32, 0.16'f32, 1.0'f32,
                      "aowlspt-invui-searchbar")
  gIuSearchLbl = nuLabel(bdGo, donor, cIuPad + 8.0'f32, cIuSearchY - 3.0'f32,
                         600.0'f32, cIuSearchH, "", cIuFontRow,
                         1.0'f32, 1.0'f32, 1.0'f32, 1.0'f32,
                         "aowlspt-invui-searchtext")
  gIuHint = nuLabel(bdGo, donor, 700.0'f32, cIuSearchY - 3.0'f32,
                    470.0'f32, cIuSearchH,
                    "type in the F6 menu's spawner row", cIuFontNote,
                    0.55'f32, 0.55'f32, 0.58'f32, 1.0'f32,
                    "aowlspt-invui-hint")
  gIuHdrLeft = nuLabel(bdGo, donor, cIuLeftX, cIuHeaderY, cIuColW, cIuHeaderH,
                       "YOUR STASH", cIuFontRow,
                       0.6'f32, 0.8'f32, 0.6'f32, 1.0'f32,
                       "aowlspt-invui-hdr-left")
  gIuHdrRight = nuLabel(bdGo, donor, cIuRightX, cIuHeaderY, cIuColW, cIuHeaderH,
                        "EVERYTHING", cIuFontRow,
                        0.8'f32, 0.75'f32, 0.6'f32, 1.0'f32,
                        "aowlspt-invui-hdr-right")
  gIuBtn = nuPanel(bdGo, cIuBtnX, cIuBtnY, cIuBtnW, cIuBtnH,
                   0.20'f32, 0.30'f32, 0.20'f32, 1.0'f32,
                   "aowlspt-invui-add")
  gIuBtnLbl = nuLabel(bdGo, donor, cIuBtnX + 10.0'f32, cIuBtnY - 8.0'f32,
                      cIuBtnW, cIuBtnH, "<- ADD", cIuFontRow,
                      1.0'f32, 1.0'f32, 1.0'f32, 1.0'f32,
                      "aowlspt-invui-add-label")
  gIuNote = nuLabel(bdGo, donor, cIuPad, cIuNoteY,
                    cIuPanelW - cIuPad * 2.0'f32, cIuNoteH,
                    "no request has been made yet", cIuFontNote,
                    0.75'f32, 0.75'f32, 0.78'f32, 1.0'f32,
                    "aowlspt-invui-note")

  var i = 0
  while i < cIuRows:                      # capped by construction
    let y = iuRowY(i)
    var lr = IuRowUi(plate: nuNone, label: nuNone, lastText: "", tpl: "", tint: -1'i32)
    lr.plate = nuPanel(bdGo, cIuLeftX, y, cIuColW, cIuRowH,
                       0.11'f32, 0.12'f32, 0.11'f32, 1.0'f32,
                       "aowlspt-invui-lrow")
    lr.label = nuLabel(bdGo, donor, cIuLeftX + 8.0'f32, y - 5.0'f32,
                       cIuColW - 12.0'f32, cIuRowH, "", cIuFontRow,
                       0.85'f32, 0.9'f32, 0.85'f32, 1.0'f32,
                       "aowlspt-invui-llbl")
    gIuLeft.add lr
    var rr = IuRowUi(plate: nuNone, label: nuNone, lastText: "", tpl: "", tint: -1'i32)
    rr.plate = nuPanel(bdGo, cIuRightX, y, cIuColW, cIuRowH,
                       0.13'f32, 0.12'f32, 0.10'f32, 1.0'f32,
                       "aowlspt-invui-rrow")
    rr.label = nuLabel(bdGo, donor, cIuRightX + 8.0'f32, y - 5.0'f32,
                       cIuColW - 12.0'f32, cIuRowH, "", cIuFontRow,
                       0.9'f32, 0.88'f32, 0.8'f32, 1.0'f32,
                       "aowlspt-invui-rlbl")
    gIuRight.add rr
    i = i + 1

  # THE ACCEPTANCE TEST FOR THE BUILD ITSELF, stated as a NEGATIVE: no element
  # this screen owns may be a dead handle. Counted rather than assumed, and a
  # single dead handle tears the whole thing down -- a panel missing four rows
  # renders as a stash with four fewer items in it, which is a lie.
  var dead = 0
  if not nuLive(gIuBackdrop): inc dead
  if not nuLive(gIuTitle): inc dead
  if not nuLive(gIuSearch): inc dead
  if not nuLive(gIuSearchLbl): inc dead
  if not nuLive(gIuHint): inc dead
  if not nuLive(gIuHdrLeft): inc dead
  if not nuLive(gIuHdrRight): inc dead
  if not nuLive(gIuBtn): inc dead
  if not nuLive(gIuBtnLbl): inc dead
  if not nuLive(gIuNote): inc dead
  for k in 0 ..< gIuLeft.len:
    if not nuLive(gIuLeft[k].plate): inc dead
    if not nuLive(gIuLeft[k].label): inc dead
  for k in 0 ..< gIuRight.len:
    if not nuLive(gIuRight[k].plate): inc dead
    if not nuLive(gIuRight[k].label): inc dead
  if dead > 0:
    gIuBuildRefused = $dead & " of the " & $(10 + gIuLeft.len * 2 +
      gIuRight.len * 2) & " elements did not come back live. Tearing the " &
      "whole screen down rather than rendering a partial one: a column " &
      "missing rows reads as a stash missing items."
    iuTeardown()
    return false

  gIuBuilt = true
  okLog "invui: BUILT -- backdrop " &
        formatFloat(float64(cIuPanelW), ffDecimal, 0) & "x" &
        formatFloat(float64(cIuPanelH), ffDecimal, 0) & " centred on a " &
        formatFloat(float64(pick.w), ffDecimal, 0) & "x" &
        formatFloat(float64(pick.h), ffDecimal, 0) & " canvas (" &
        pick.verdict & "), " & $cIuRows & " rows per column, donor TMP 0x" &
        hexOf(cast[uint64](donor)) & " found after " & $scanned &
        " node(s). " & $int(cNkLiveCount()) & " of " & $int(cNkCapacity()) &
        " nuikit handles live."
  true

# ---------------------------------------------------------------------------
# ARMING. The pointer mapping is only valid for a ScreenSpaceOverlay canvas, so
# ASK -- through the field UNITY filled by its own ancestor walk, which is a
# better answer than any walk of ours because it is the canvas that will really
# draw this element. Under any other mode the mapping still returns finite
# numbers and they are fiction.
# ---------------------------------------------------------------------------
proc iuArm(): bool =
  if gIuArmed: return true
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(gIuBackdrop, "iuArm", go, rt, comp, kind): return false
  if not nuOk(comp, cIuOffGraphicCanvas + 0x8'i32): return false
  let canvas = cNuGetRef(comp, cIuOffGraphicCanvas)
  if canvas == nil or not nuOk(canvas, 0x20'i32) or not nuAlive(canvas):
    if not gIuArmRefusalLogged:
      gIuArmRefusalLogged = true
      warn "invui: NOT arming interaction -- the backdrop's Graphic.m_Canvas " &
           "(@0x60) is null or not a live object. Unity fills it in OnEnable " &
           "by ancestor walk, so this means the panel has no Canvas above it " &
           "and is not being drawn at all. It stays visible-but-inert rather " &
           "than mapping the pointer through a canvas that does not exist."
    return false
  let fn = nuFn(NuTCanvasGetMode)
  if fn == nil: return false
  # -1 is not a legal RenderMode, so "could not ask" can never be mistaken for
  # ScreenSpaceOverlay(0) -- the exact value being tested for.
  let mode = cNuCallIP(fn, canvas, -1'i32)
  if mode != cIuOverlayMode:
    if not gIuArmRefusalLogged:
      gIuArmRefusalLogged = true
      warn "invui: NOT arming interaction -- the backdrop's Canvas reports " &
           "renderMode=" & $mode & ", and the pointer mapping is only valid " &
           "for ScreenSpaceOverlay(" & $cIuOverlayMode & "). The panel " &
           "renders and does not respond; that is a REFUSAL, not a failure."
    return false
  okLog "invui: interaction ARMED -- the backdrop's Canvas renderMode reads " &
        $mode & " (ScreenSpaceOverlay), so world space IS screen space and " &
        "the pointer mapping is valid"
  gIuArmed = true
  true

proc iuHit(e: NuElem; mx, my: float32): bool =
  ## Is the pointer over this element? Every rejection rejects the WHOLE hit --
  ## an unresolvable handle or an unmappable rect is "not hit", never "hit".
  var go: Il2CppPtr = nil
  var rt: Il2CppPtr = nil
  var comp: Il2CppPtr = nil
  var kind = 0'i32
  if not nkResolve(e, "iuHit", go, rt, comp, kind): return false
  var sx = 0.0'f32
  var sy = 0.0'f32
  var sw = 0.0'f32
  var sh = 0.0'f32
  if not nuScreenRectOf(rt, sx, sy, sw, sh): return false
  cNuRectContains(sx, sy, sw, sh, mx, my) != 0'i32

# ---------------------------------------------------------------------------
# RENDER. Text is written ONLY when it CHANGES (rule 7): `lastText` is compared
# first, so a settled screen makes zero `nuSetText` calls and interns nothing.
# ---------------------------------------------------------------------------
proc iuSetIfChanged(e: NuElem; cur: var string; want: string) =
  if cur == want: return
  if nuSetText(e, want):
    cur = want

proc iuRenderRows() =
  ## Both columns, from whichever side of the region is currently OURS to read.
  ## `*Ready` is false while a request is in flight, and a not-ready column is
  ## LEFT ALONE rather than blanked: blanking would make every keystroke flash
  ## the list empty, which reads as "no matches" for the duration.
  if cIuStashReady() != 0'i32:
    let n = int(cIuStashCount())
    var i = 0
    while i < gIuRight.len:                       # capped: cIuRows
      if i < n:
        let nm = iuStashName(i)
        let tpl = iuStashTpl(i)
        gIuRight[i].tpl = tpl
        iuSetIfChanged(gIuRight[i].label, gIuRight[i].lastText,
                       iuClip(nm, 52))
        # Selection is shown by PLATE COLOUR. The wanted tint is recomputed
        # every pass -- row 3 after a new search is a different item than row 3
        # before it, so the selection highlight cannot be left where it was --
        # but it is only WRITTEN when it differs from what is already there.
        let want = (if tpl.len > 0 and tpl == gIuSelTpl: 1'i32 else: 0'i32)
        if gIuRight[i].tint != want:
          if want == 1'i32:
            discard nuSetColor(gIuRight[i].plate,
                               0.30'f32, 0.26'f32, 0.10'f32, 1.0'f32)
          else:
            discard nuSetColor(gIuRight[i].plate,
                               0.13'f32, 0.12'f32, 0.10'f32, 1.0'f32)
          gIuRight[i].tint = want
      else:
        gIuRight[i].tpl = ""
        iuSetIfChanged(gIuRight[i].label, gIuRight[i].lastText, "")
        if gIuRight[i].tint != 2'i32:
          discard nuSetColor(gIuRight[i].plate,
                             0.09'f32, 0.09'f32, 0.09'f32, 1.0'f32)
          gIuRight[i].tint = 2'i32
      i = i + 1
    let matched = int(cIuStashMatched())
    iuSetIfChanged(gIuHdrRight, gIuLastHdrR,
                   "EVERYTHING  --  showing " & $(if n < gIuRight.len: n
                                                  else: gIuRight.len) &
                   " of " & $matched & " match(es)")

  if cIuInvReady() != 0'i32:
    let n = int(cIuInvCount())
    var i = 0
    while i < gIuLeft.len:                        # capped: cIuRows
      if i < n:
        let nm = iuInvName(i)
        let q = int(cIuInvQty(int32(i)))
        iuSetIfChanged(gIuLeft[i].label, gIuLeft[i].lastText,
                       (if q > 1: "x" & $q & "  " else: "") & iuClip(nm, 46))
      else:
        iuSetIfChanged(gIuLeft[i].label, gIuLeft[i].lastText, "")
      i = i + 1
    let total = int(cIuInvTotal())
    iuSetIfChanged(gIuHdrLeft, gIuLastHdrL,
                   "YOUR STASH  --  showing " & $(if n < gIuLeft.len: n
                                                  else: gIuLeft.len) &
                   " of " & $total & " template(s)")

proc iuRenderChrome() =
  ## The search text, the button caption and the note line.
  let q = iuTypedQuery()
  iuSetIfChanged(gIuSearchLbl, gIuLastSearchTxt,
                 (if q.len > 0: "> " & q else: "> (type to search)"))
  iuSetIfChanged(gIuNote, gIuLastNote, iuClip(iuNoteText(), 190))
  # The button says what it WILL do, including when it will do nothing. A button
  # captioned "ADD" that is inert because nothing is selected is the silent
  # no-op this project keeps paying for.
  let cap = (if cIuMintBusy() != 0'i32: "working..."
             elif gIuSelTpl.len == 0: "select ->"
             else: "<- ADD")
  iuSetIfChanged(gIuBtnLbl, gIuLastBtnTxt, cap)
  # Same change-gate as the row plates: the button's tint follows whether
  # anything is selected, which changes on a click and not on a frame.
  let btnWant = (if gIuSelTpl.len == 0: 0'i32 else: 1'i32)
  if gIuBtnTint != btnWant:
    if btnWant == 1'i32:
      discard nuSetColor(gIuBtn, 0.20'f32, 0.34'f32, 0.20'f32, 1.0'f32)
    else:
      discard nuSetColor(gIuBtn, 0.16'f32, 0.16'f32, 0.17'f32, 1.0'f32)
    gIuBtnTint = btnWant

# ---------------------------------------------------------------------------
# THE TICK BODY -- inside the ONE guard `aowl_iu_tick_guarded` opened. This
# proc opens NO guard of its own: `aowl_p_p_seh` is not re-entrant and a nested
# inner guard disarms the outer one.
# ---------------------------------------------------------------------------
proc iuTickBody(a: Il2CppPtr): Il2CppPtr {.exportc: "aowl_iu_tick_body", cdecl.} =
  if not gIuBuilt: return cast[Il2CppPtr](1)

  # VISIBILITY. Tied to the F6 menu, because that is where the keystrokes this
  # screen reads are captured. A search bar that is on screen while the keyboard
  # is going to the game would be a control that cannot be used.
  let wantVisible = cIuAdminMenuOpen() != 0'i32
  if wantVisible != gIuVisible:
    gIuVisible = wantVisible
    var go: Il2CppPtr = nil
    var rt: Il2CppPtr = nil
    var comp: Il2CppPtr = nil
    var kind = 0'i32
    if nkResolve(gIuBackdrop, "iuVisible", go, rt, comp, kind):
      discard nuSetActive(go, wantVisible)
    if wantVisible:
      # Opening is the one moment both columns are certainly stale.
      if cIuAskInv() != 0'i32: gIuInvAsks = gIuInvAsks + 1
      gIuLastQuery = ""          # force the query mirror to re-ask
  if not gIuVisible: return cast[Il2CppPtr](1)

  # THE QUERY MIRROR. Bounded by CHANGE, not by time: one string compare per
  # tick while the query is settled, and no cross-process request at all.
  let q = iuTypedQuery()
  if q != gIuLastQuery:
    var qq = q
    if cIuAskStash(toCString(qq)) != 0'i32:
      gIuLastQuery = q
      gIuStashAsks = gIuStashAsks + 1
    # A 0 here means a request is already in flight. `gIuLastQuery` is
    # deliberately NOT updated in that case, so the newest text is re-offered
    # next tick instead of being dropped -- the alternative is a list that
    # belongs to a query the player has already typed past.

  # A mint invalidates the left column. Re-ask once the mint's ack has landed,
  # a few ticks later, so the read is of the profile AFTER the write.
  if gIuInvRefresh > 0'i64 and gIuTicks >= gIuInvRefresh:
    gIuInvRefresh = 0'i64
    if cIuAskInv() != 0'i32: gIuInvAsks = gIuInvAsks + 1

  iuRenderRows()
  iuRenderChrome()

  if not iuArm(): return cast[Il2CppPtr](1)

  var mx = 0.0'f32
  var my = 0.0'f32
  if not nuMousePos(mx, my):
    gIuPrevDown = false        # a held button with no position is not a click
    return cast[Il2CppPtr](1)
  let down = nuMouseDown(0'i32)
  let pressed = down and not gIuPrevDown    # EDGE, not level
  gIuPrevDown = down
  if not pressed: return cast[Il2CppPtr](1)

  # Row selection. First hit wins and the loop stops -- rows do not overlap, so
  # a second hit would be a layout bug and continuing would hide it.
  var i = 0
  while i < gIuRight.len:                   # capped: cIuRows
    if gIuRight[i].tpl.len > 0 and iuHit(gIuRight[i].plate, mx, my):
      gIuSel = i
      gIuSelTpl = gIuRight[i].tpl
      okLog "invui: selected row " & $i & " -- " & gIuRight[i].lastText &
            " (" & gIuSelTpl & ")"
      return cast[Il2CppPtr](1)
    i = i + 1

  if iuHit(gIuBtn, mx, my):
    if gIuSelTpl.len == 0:
      # Announced, not swallowed. A press that does nothing and says nothing is
      # indistinguishable from a press that was not registered.
      okLog "invui: ADD pressed with nothing selected -- click a row in the " &
            "right-hand column first. Nothing was requested."
    elif cIuMintBusy() != 0'i32:
      okLog "invui: ADD pressed while a mint is still in flight -- refused " &
            "rather than queued. The note line carries the first one's result."
    else:
      var t = gIuSelTpl
      if cIuAskMint(toCString(t), 1'i32, 100'i32) != 0'i32:
        gIuMintsAsked = gIuMintsAsked + 1
        # ~30 ticks (~0.5s at 60fps) before re-reading the left column. The
        # backend brackets the spawn with two profile reads; asking sooner would
        # read the stash the mint has not been written into yet and render a
        # correct spawn as a missing one.
        gIuInvRefresh = gIuTicks + 30'i64
        okLog "invui: mint requested for " & gIuSelTpl &
              " x1 at condition 100. The verdict will be the BACKEND'S " &
              "profile readback, not this request returning."
      else:
        okLog "invui: the mint request was REFUSED by the region (a request " &
              "is already outstanding, or the region is not compatible)"
  cast[Il2CppPtr](1)

# ---------------------------------------------------------------------------
# THE VERDICT -- PASS / FAIL / INCONCLUSIVE, never two outcomes.
# ---------------------------------------------------------------------------
proc iuVerdict(): string =
  if not gIuOn:
    return "invui VERDICT = INCONCLUSIVE -- the feature is flagged OFF " &
           "(nativeInvUi), so nothing was built and nothing was examined. " &
           "That is not a pass."
  if cIuDisabled() != 0'i32:
    return "invui VERDICT = FAIL -- SELF-DISABLED after " & $cIuFaultCount() &
           " guarded fault(s) (cap " & $cIuMaxFaults() & "). The guard caught " &
           "every one and the game survived; the panel stays on screen and " &
           "stops responding."
  if not gIuBuilt:
    return "invui VERDICT = INCONCLUSIVE -- the panel has NOT been built, so " &
           "nothing was examined. Reason: " &
           (if gIuBuildRefused.len > 0: gIuBuildRefused
            else: "no build has been attempted yet (the Unity drain has not " &
                  "reached it)") & " That is not a pass."

  # THE STRUCTURAL HALF, stated as a NEGATIVE and READ BACK: no element this
  # screen owns fails to report itself live. `nuLive` asks the object, it does
  # not consult what we remembered creating.
  var deadElems = 0
  var liveElems = 0
  for k in 0 ..< gIuLeft.len:
    if nuLive(gIuLeft[k].label): inc liveElems else: inc deadElems
    if nuLive(gIuLeft[k].plate): inc liveElems else: inc deadElems
  for k in 0 ..< gIuRight.len:
    if nuLive(gIuRight[k].label): inc liveElems else: inc deadElems
    if nuLive(gIuRight[k].plate): inc liveElems else: inc deadElems
  if not nuLive(gIuBackdrop): inc deadElems else: inc liveElems

  # THE BEHAVIOURAL HALF: has anything actually rendered TEXT? A row that is
  # live with an empty caption is a row that renders nothing, and counting it
  # as a success is exactly the check that cannot fail.
  var rowsWithText = 0
  for k in 0 ..< gIuRight.len:
    if nuElemText(gIuRight[k].label).len > 0: inc rowsWithText
  for k in 0 ..< gIuLeft.len:
    if nuElemText(gIuLeft[k].label).len > 0: inc rowsWithText

  let tail = " (elements live=" & $liveElems & " dead=" & $deadElems &
             " rowsWithText=" & $rowsWithText &
             " armed=" & $gIuArmed & " visible=" & $gIuVisible &
             " stashAsks=" & $gIuStashAsks & " invAsks=" & $gIuInvAsks &
             " mintsAsked=" & $gIuMintsAsked &
             " heartbeat=" & $int(cIuHeartbeat()) &
             " faults=" & $cIuFaultCount() & ")"

  if deadElems > 0:
    return "invui VERDICT = FAIL -- " & $deadElems & " element(s) this screen " &
           "owns are no longer live objects, so the panel is rendering with " &
           "holes in it" & tail
  if int(cIuHeartbeat()) == 0:
    return "invui VERDICT = INCONCLUSIVE -- the panel is built and every " &
           "element is live, but the backend has NEVER serviced a request " &
           "(heartbeat 0). Nothing has been read back, so this says the " &
           "screen is DRAWN and nothing about whether it works" & tail
  if rowsWithText == 0:
    return "invui VERDICT = INCONCLUSIVE -- the backend has answered but NOT " &
           "ONE row renders any text. Either every request matched nothing, " &
           "or the text is not reaching the TMPs. This does not establish " &
           "either" & tail

  # THE MINT, which is the only claim that matters and the only one this host
  # cannot make for itself. The numbers are the BACKEND'S profile readback.
  let mv = int(cIuVerdict())
  let before = int(cIuMintBefore())
  let after = int(cIuMintAfter())
  if gIuMintsAsked == 0 or mv == 0:
    return "invui VERDICT = INCONCLUSIVE -- the screen renders " &
           $rowsWithText & " row(s) of real text and the backend is " &
           "answering, but NO MINT has been attempted, so nothing has been " &
           "spawned and nothing was verified" & tail
  if mv == 3:
    return "invui VERDICT = INCONCLUSIVE -- a mint ran and the backend could " &
           "NOT READ THE PROFILE BACK, so whether the item arrived is " &
           "unknown. \"I could not look\" is not a pass" & tail
  if mv == 2:
    return "invui VERDICT = FAIL -- a mint ran and the profile held " &
           $before & " of that template before and " & $after & " after. It " &
           "did not arrive" & tail
  "invui VERDICT = PASS -- the panel renders " & $rowsWithText & " row(s) of " &
  "real text with no dead element, and the last mint was confirmed by the " &
  "backend's own PROFILE READBACK: " & $before & " -> " & $after & tail

# ---------------------------------------------------------------------------
# THE DRAIN CALL SITE. Rides `EFT.TarkovApplication::Update` -- NO detour of its
# own. A second detour on one function overwrites the first's trampoline and
# silently kills it, so this is a call site on the existing drain, exactly like
# `natEspDrainTick` and `cwDrainTick`.
#
# Idle cost with the flag off: one boolean compare and no call into the game.
# ---------------------------------------------------------------------------
proc iuDrainTick() =
  if not gIuOn: return
  if cIuDisabled() != 0'i32: return
  if cNuDisabled() != 0'i32: return
  gIuTicks = gIuTicks + 1

  if not gIuBuilt:
    # Retried on a slow cadence, not every frame: the canvas and the donor
    # appear only once the menu scene is up, and a per-frame scene walk before
    # then is a cost paid for nothing. Every ~2s at 60fps.
    if (gIuTicks mod 120'i64) == 1'i64:
      if not iuBuild():
        if (gIuTicks mod 1800'i64) == 1'i64 and gIuBuildRefused.len > 0:
          # Every ~30s, not every attempt: this is a waiting state, not an
          # error, until the menu scene exists.
          okLog "invui: not built yet -- " & gIuBuildRefused
    return

  if (gIuTicks mod 300'i64) == 0'i64:
    let v = iuVerdict()
    if v != gIuLastVerdict:
      gIuLastVerdict = v
      okLog v

  if cIuTickGuarded(nil) == nil:
    cIuNoteFault()
    if cIuDisabled() != 0'i32:
      warn "invui: SELF-DISABLED after " & $cIuFaultCount() & " fault(s) " &
           "(cap " & $cIuMaxFaults() & "). The guard caught every one and the " &
           "game survived; the panel stays on screen and stops responding. No " &
           "further call is made into the game from this path."
    else:
      warn "invui: the guard caught a fault in the tick (" & $cIuFaultCount() &
           " of " & $cIuMaxFaults() & " before this path self-disables)"

proc bindInvUi(on: bool) =
  gIuOn = on
  if not on:
    if gIuBuilt: iuTeardown()
    okLog "invui: OFF (nativeInvUi). The native inventory screen is not " &
          "built; the F6 item spawner is unaffected and unchanged."
    return
  okLog "invui: ON (nativeInvUi) -- a native Unity UI inventory screen built " &
        "from nuikit primitives (no game widget is cloned). Two columns of " &
        $cIuRows & " rows, shown with the F6 menu, fed by the shared region " &
        "Local\\aowlspt_invui_v1 which mods/admin drains on the server side " &
        "through aowl.items. Search text is MIRRORED from the F6 spawner's " &
        "own keystroke capture -- click-to-type is NOT implemented and the " &
        "panel says so on screen. Selection and the ADD button are POLLED " &
        "off the TarkovApplication::Update drain through " &
        "UnityEngine.Input::GetMouseButton@0x531EBD0 and " &
        "get_mousePosition_Injected@0x531F740, both byte-verified against " &
        "the startup snapshot and both sharedness=UNIQUE. Interaction arms " &
        "only after Graphic.m_Canvas@0x60 reads back a ScreenSpaceOverlay " &
        "Canvas. Self-disables after " & $cIuMaxFaults() & " faults. A mint " &
        "is reported PASS only when the BACKEND'S profile readback shows the " &
        "template count went UP."
