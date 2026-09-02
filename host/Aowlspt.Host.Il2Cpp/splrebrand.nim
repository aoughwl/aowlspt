# splrebrand.nim -- rebrand the "PRACTICE GAME MODE" block on the Matchmaker
# Offline Raid Screen as aowlspt SINGLEPLAYER, and hide the practice-mode
# checkbox, WITHOUT touching the offline routing.
#
# `include`d into `aowlhost.nim` AFTER `nativeui.nim`, `debugui.nim` and
# `inspect.nim`, because it borrows a byte-verified primitive from each and
# adds NO C targets and NO header of its own:
#   * from `nativeui.nim` -- `nuFn`/`nuOk`/`nuStr` and the call thunks, the
#     real setters `TMP_Text::set_text`(NuTTmpSetText) and
#     `LocalizedText::SetLabelText`(NuTLocSetLabelText), plus `nuSetActive`,
#     `nuActiveInHierarchy`. Every one is resolved by RVA + startup-snapshot
#     prologue verify inside `cNuFn`, independent of the `nativeUi` flag, so
#     this feature does not depend on another feature being enabled.
#   * from `inspect.nim`  -- `iSceneRoots` (the DontDestroyOnLoad-aware root
#     walk), `iChildCount`/`iChildAt`/`iObjName`/`iToTransform`/`iHierRoot`,
#     `iUnityAlive`, `iFindTarget`/`iTargetFn`/`iMark`, `iInspSeedTextType`
#     and its cached `gTxtTypeStr`, and `iIsKnownKlass`.
#   * from `debugui.nim`  -- `duOk`, the every-hop VirtualQuery.
#
# WHAT THE USER SEES / WANTS
# --------------------------
# On the Matchmaker Offline Raid Screen (reached via recipe `enter-offline-raid`,
# under the `Menu UI` scene root) there is:
#   * a heading  "PRACTICE GAME MODE"
#   * a description  "In this mode, you can practice offline ..."
#   * a checkbox "Enable practice mode for this raid" (label at
#     Content/NonLayoutContainer/SoloModeCheckmarkBlocker/Label; the control is
#     `EFT.UI.UpdatableToggle` on the SoloModeCheckmarkBlocker GameObject --
#     fact #71).
# This feature relabels the heading + description to SINGLEPLAYER branding and
# SetActive(false)s the checkbox's GameObject.
#
# FORCE THE TOGGLE, THEN HIDE (corrected 2026-08-28)
# --------------------------------------------------
# The coordinator's correction: offline/singleplayer likely REQUIRES the box
# CHECKED, so hiding it while unchecked could drop the raid out of offline. So
# this now FORCES the value before hiding, in this order (order matters):
#   1. `Toggle::set_isOn(SplForceIsOn)` on the UpdatableToggle -- the NOTIFYING
#      setter, byte-verified @0x55BA430 (fact #71), re-asserted once. It runs the
#      game's onValueChanged listener (the thing that actually selects the mode);
#      a raw m_IsOn store would move the field WITHOUT running it.
#   2. read m_IsOn(+0x120) BACK and assert it equals the wanted value -- a
#      readback that can FAIL (CLAUDE.md 9b). Only on PASS do we hide.
#   3. `SetActive(false)` to hide the (now correctly-valued) checkbox.
# If set_isOn does not verify, or the readback does not match, this REFUSES to
# hide and leaves the box VISIBLE rather than hidden-with-an-unknown-value.
#
# WHICH WAY IT GATES IS UNCONFIRMED -- INCONCLUSIVE, flagged for live check.
# The original report ("unchecked AND offline") and the correction ("offline
# needs checked") conflict, and it cannot be settled offline on this machine
# (no decrypted metadata / no GameAssembly.dll here to disassemble the
# UpdatableToggle handler). So `SplForceIsOn = true` follows the user's stated
# expectation; if a live raid comes up ONLINE after this, flip that ONE const.
# This feature never claims anything about loot/XP persistence.
#
# DISCOVERY IS LIVE AND BY CONTENT, NEVER A HARDCODED PATH (fact #104)
# -------------------------------------------------------------------
# A hardcoded child path that does not exist FAULTS and self-disables. So the
# screen is found by object NAME ("Matchmaker Offline Raid Screen") from a
# verified scene root, then the three targets are found by the TEXT they DISPLAY
# (the same signal `findtext` and the recipe's `find_text` use), each hop
# guarded. A miss is a quiet return (the screen only exists once the user
# navigates to it), never a fault.
#
# SAFETY (all eight rules)
# ------------------------
#   * flag-gated `singleplayerRebrand`, DEFAULT OFF;
#   * every managed target is 16-byte prologue-verified in `cNuFn` before it is
#     called (byte-compared to the startup snapshot), so on any other build
#     this is a silent no-op;
#   * the whole per-tick body runs under ONE `aowl_p_p_seh` (`cSplTickGuarded`)
#     -- one, never nested;
#   * every pointer hop is `duOk`/`nuOk`-guarded before it is dereferenced, and
#     `iUnityAlive` before any icall;
#   * every walk is bounded by a node budget AND an in-walk wall-clock deadline;
#   * self-disables after `SplMaxFaults` guarded bodies fault;
#   * NO PER-FRAME MANAGED ALLOCATION: the branding strings are INTERNED once
#     via `nuStr`, and the whole body is throttled to ~1 Hz while hunting and
#     slower once done -- it rides the existing `TarkovApplication::Update`
#     drain (a slot alias, NOT a second detour).

# ---- the exact stock text this screen ships (lower-cased for matching) ----
const
  SplScreenName   = "Matchmaker Offline Raid Screen"
  # The offline-raid screen lives under one of these DontDestroyOnLoad roots
  # (measured: "Menu UI"). Search them FIRST -- the early roots like
  # "Application (Main Client)" are enormous and a plain 0..N walk burns the
  # whole time-slice on them before ever reaching Menu UI (root ~#20 of 22).
  SplUiRoot0      = "Menu UI"
  SplUiRoot1      = "Common UI"
  # The three targets are found by CONTAINER NAME (measured live within the
  # screen), NOT by reading TMP text on every node -- the ~494-node subtree's
  # per-node TMP reads blew the 18ms slice before reaching the shallow captions,
  # and the description is a LocalizedText whose m_text does not even contain the
  # visible words, so text-matching could never find it.
  SplHeadNode     = "MainCaption"              # heading TMP ("Practice game mode")
  SplDescNode     = "Description"              # the "In this mode..." blurb (LocalizedText)
  SplWarnNode     = "WarningPanelHorLayout"    # the WHOLE co-op/EoD warning panel
                                               # (Background+Glow+Icon+WarningTextVertLayout);
                                               # hiding only the text layout left the Icon.
  SplBlockerName  = "SoloModeCheckmarkBlocker"
  SplHeadStock    = "practice game mode"
  SplDescStock    = "in this mode"
  SplToggleStock  = "enable practice mode for this raid"
  # ---- the co-op / Edge-of-Darkness "your progress is not saved/shared"
  # warning, hidden whole. Matched by DISPLAYED TEXT within THIS screen only
  # (the global findtext could never surface it -- the 16-root search exhausted
  # its node budget every time). The predicate is deliberately narrow so it can
  # NEVER catch the unrelated weapon warning "ATTENTION! Your weapon doesn't
  # have the required vital part": it requires "progress" AND a corroborating
  # co-op/not-saved token, AND explicitly EXCLUDES "vital part"/"weapon".
  SplWarnStock    = "progress"
  SplWarnExclA    = "vital part"
  SplWarnExclB    = "weapon"
  # ---- what we replace them with. Factual; no persistence claim. ----
  SplHeadNew      = "SINGLEPLAYER"
  SplDescNew      = "aowlspt - a local single-player raid against the emulated server."
  # Pre-lowered forms of the two above. The steady-state check now runs EVERY
  # frame (see `SplSteadyFrames`), so lowering a compile-time constant on every
  # frame would be two pointless heap allocations per frame; these are the same
  # strings, written lowercase by hand. If SplHeadNew/SplDescNew change, change
  # these with them.
  SplHeadNewLow   = "singleplayer"
  SplDescNewLow   = "aowlspt - a local single-player raid against the emulated server."
  # ---- the practice toggle, forced ON before it is hidden ----
  # `aowl_sw_targets[AOWL_SW_TOGGLE_SET_ISON]` = UnityEngine.UI.Toggle::set_isOn
  # @0x55BA430, byte-verified (16-byte prologue vs the startup snapshot) inside
  # `cSwFn2`; a mismatch returns nil and this feature REFUSES to touch the box.
  SplToggleSetIsOn = 1'i32
  # WHICH WAY DOES THE BOX GATE OFFLINE? UNCONFIRMED. The user's original report
  # was "unchecked AND offline"; the correction is "offline likely REQUIRES
  # checked". I cannot settle it offline on this machine (no decrypted metadata,
  # no GameAssembly.dll here, so the UpdatableToggle::onValueChanged handler
  # cannot be disassembled), so this is INCONCLUSIVE and must be confirmed live.
  # We force the box to the user's stated expectation (ON = checked). If a live
  # deploy shows forcing ON drops us ONLINE, flip this ONE const to `false`
  # (force OFF) -- do NOT re-derive the plumbing.
  SplForceIsOn    = true

# ---- bounds ----
const
  SplWarmupMs     = 5000'u64   ## the menu is not up before this; do not walk.
  SplHuntFrames   = 60         ## ~1 s at 60 fps while NOTHING is cached (the
                               ## `iSceneRoots` enumeration allocates; it may not
                               ## run per frame).
  SplCheapHuntFrames = 6       ## ~100 ms at 60 fps once the UI ROOT ("Menu UI")
                               ## is cached but the screen is not.
                               ##
                               ## THIS WAS 1 -- every frame -- on the reasoning
                               ## that "the expensive part of a hunt was never
                               ## the descent, it was iSceneRoots", so the
                               ## descent allocates nothing and can run freely.
                               ## MEASURED 2026-09-01 with the host's own
                               ## drainProfiler, that reasoning is WRONG: this
                               ## tier cost 2,590,859us across 90 calls -- a
                               ## MEAN OF 28.8 MILLISECONDS PER CALL, 47.4% of
                               ## the whole feature -- and the feature's total
                               ## was 5.46 SECONDS of Unity main-thread time
                               ## with a single call peaking at 79ms.
                               ##
                               ## "Allocates nothing" is not the same as
                               ## "cheap". Walking a live Unity tree by name is
                               ## thousands of interop calls, and Tarkov is
                               ## main-thread bound -- every millisecond here is
                               ## taken from bot AI and rendering. A cosmetic
                               ## relabel must not compete with the game for the
                               ## one contended resource.
                               ##
                               ## 6 frames costs at most ~100ms of extra vanilla
                               ## text on first open and cuts this tier's
                               ## main-thread cost by 6x. Frequency is the only
                               ## safe lever here: the walk keeps no resume
                               ## cursor, so shortening its time slice could
                               ## stop it reaching the screen at all.
  SplRescanFrames = 6          ## ~100 ms once the SCREEN transform is cached but
                               ## its TMPs are not: a depth-12 scan bounded by
                               ## SplWalkMs, no root enumeration.
  SplSteadyFrames = 1          ## EVERY FRAME once the targets are cached.
                               ## THIS IS THE FLASH FIX. It was 180 (~3 s), and
                               ## that is exactly the window in which the player
                               ## saw BSG's "PRACTICE GAME MODE" after the screen
                               ## was (re)opened and LocalizedText re-applied the
                               ## stock caption. Mirrors `hide seasons`
                               ## (modstab.nim ~3439): the expensive walk stays
                               ## throttled, the cheap re-assert from the CACHED
                               ## object runs every frame. Cost per frame in this
                               ## state: three ICALLs (activeInHierarchy) and two
                               ## raw m_text reads -- no scene walk, no managed
                               ## allocation, no set_isOn (the checkbox is
                               ## already hidden, so that branch is skipped).
  SplWalkMs       = 18'u64     ## per-pass wall-clock slice, checked INSIDE the walk.
                               ##
                               ## LEFT AT 18ms DELIBERATELY, and the reason is
                               ## worth stating because the obvious "fix" is
                               ## wrong. A 60 fps frame is 16.7ms, so this slice
                               ## exceeds a whole frame budget and the measured
                               ## mean was 28.8ms -- so it is not even bounding
                               ## the pass. Cutting it looks right.
                               ##
                               ## But `splFindByName` KEEPS NO RESUME CURSOR: it
                               ## restarts from the root on every pass. A shorter
                               ## slice therefore does not cost more passes to
                               ## reach the same depth -- it may never reach the
                               ## target at all, and the feature would silently
                               ## stop finding the screen while looking faster.
                               ## That is a worse bug than the cost.
                               ##
                               ## So the cost is cut by FREQUENCY instead (see
                               ## SplCheapHuntFrames). Making the walk resumable
                               ## is the real fix and is not done here.
  SplNodeBudget   = 24000      ## per-ROOT node cap (reset per root), threaded through the
                               ## recursion. The offline-raid screen sits deep in the large
                               ## "UI" root (the live inspector only reached it after ~thousands
                               ## of nodes), so 3000 shared across all roots exhausted before
                               ## reaching it -- the silent nil that hid this bug.
  SplFanout       = 256        ## children examined per level -- the "UI" root has many child
                               ## screens; 64 could cut off the target sibling.
  SplFindDepth    = 8          ## depth for the screen-by-name descent.
  # ---- THE PER-FRAME TIER-1 DESCENT: its own, much smaller bounds. ----
  # MEASURED (aowlspt-host.log of the 146412a run, phase meter):
  #   `DESCEND splFindByName, by-name descent: 2664411.7us over 113 calls
  #    (mean 23578.8us, max 40238.8us, 38.1% of total)`
  # and `UI-root cache hits=92` -- i.e. most of those calls were the tier-1
  # descent from the cached "Menu UI" root, which this file described as
  # "cheap" and "~100 nodes to a shallow screen". It is only cheap when it
  # HITS. On a MISS -- the normal state, because the offline-raid screen is
  # closed most of the time -- it burns the whole SplNodeBudget (24000) and the
  # whole SplWalkMs (18ms) proving a negative, every frame.
  #
  # The bounds below are sized from this file's OWN measured claim about the
  # hit case: "Menu UI -> UI -> screen, depth 2", "found in ~100 nodes". Depth
  # 4 and 2500 nodes is a >20x margin on both. A MISS at these bounds is not
  # treated as proof of absence: it falls through to the wide walk, which is
  # throttled but keeps the FULL SplFindDepth/SplNodeBudget, so nothing that
  # was findable before becomes unfindable -- only the per-frame price drops.
  # ---- THE TIER-1 BOUND. It was depth 4 / 2500 nodes / 2 ms, and THAT BROKE
  # THE FEATURE (measured: the live log filled with `screen "Matchmaker Offline
  # Raid Screen" WAS found, but its heading TMP ... was not read`, then
  # `... yielded no targets on 20 consecutive re-scans`, on a loop -- the player
  # saw vanilla). Those bounds came from a comment in this file claiming the hit
  # case is "depth 2, ~100 nodes"; sizing a live bound from a comment is a
  # guess, and it was wrong.
  #
  # `splFindByName` is breadth-before-depth PER NODE, so a DEPTH CAP does not
  # merely truncate the search -- it can return a DIFFERENT node of the same
  # name. A shallow same-named container whose subtree holds no `MainCaption`
  # will then be cached as "the screen", the scan under it correctly finds
  # nothing, and the feature spins. That is why the depth cap is gone entirely
  # rather than merely raised: the bound is now the SAME one the wide walk
  # uses, so tier 1 and the wide walk cannot disagree about which node is the
  # screen.
  #
  # The per-frame cost this was meant to fix is bought back instead by not
  # REPEATING fruitless work -- the rejected-screen ledger and the resolved-path
  # cache below -- which is the only kind of saving that cannot shrink a search
  # that has to succeed.
  SplCheapMs      = SplWalkMs
  SplScanDepth    = 12         ## depth for the by-text scan within the screen.
  SplBlockerUp    = 5          ## how far to climb from the toggle label to the blocker.
  SplWarnUp       = 4          ## how far to climb from the warning TMP to its panel container.
  SplMaxFaults    = 3

# ---------------------------------------------------------------------------
# THE SHOW-EVENT WINDOW -- what replaced the forever-cadence
# ---------------------------------------------------------------------------
# Everything above this line describes a feature that HUNTED for its screen on a
# cadence, forever. The user's report, verbatim, 2026-09-01:
#
#   "that singleplayer rebrand + version rebrand + other stuff should NOT
#    constantly poll for some ui element to disable/hide it- that is very not
#    performant!!!!!"
#
# They are right, and the host log agreed with them: the ~10 Hz hunt was cut off
# by its own 18 ms wall-clock slice after 64 nodes on EVERY pass, all session,
# resolving nothing. That is pure loss -- main-thread interop spent to produce a
# refusal.
#
# The trigger is now `uihooks.nim`: a POSTFIX detour on
# `MatchmakerOfflineRaidScreen::Show` @0x1788590 (UNIQUE, 16-byte prologue
# verified) hands us the LIVE SCREEN OBJECT the moment the game shows it. From
# that object the targets are reachable by a BOUNDED walk OF ONE SCREEN --
# `splScanNode`, which is what the wide walk fed anyway -- so the scene-root
# enumeration (`iSceneRoots`), the "Menu UI" descent and the rejected-screen
# ledger are all unnecessary and are no longer entered.
#
# WHY A WINDOW AND NOT A SINGLE SHOT. Two measured reasons, both of which a
# one-shot would get wrong:
#   * at `Show` POSTFIX time the screen's children exist but the caption may not
#     be populated yet, so a single scan can legitimately miss;
#   * `LocalizedText` CLOBBERS a caption after we set it (CLAUDE.md sec.5), so
#     the relabel has to be re-asserted, not merely issued.
# So each show event opens a bounded window of frames during which the existing
# per-frame re-assert runs -- from CACHED pointers, no walking -- and the window
# then CLOSES. Outside a window this feature does nothing at all: the drain
# rider returns on an integer compare. The window re-opens on the next show
# event, which is the design, not a leak.
const
  SplShowWindowFrames = 1800
    ## Hard cap on the frames one show event may keep this feature working
    ## (~30 s at 60 fps). A cap, not the expected cost -- the window normally
    ## closes far earlier, on SplSettleFrames below.
  SplSettleFrames = 90
    ## Once the FINISHED-STATE readback has passed for this many CONSECUTIVE
    ## frames, close the window early. This is a settle test on the state we
    ## assert, not on our own writes: it counts frames on which the live TMP
    ## already read ours and the checkbox already read inactive, i.e. frames on
    ## which we did nothing. A stretch of those is the only honest evidence that
    ## `LocalizedText` has stopped fighting us.
  SplRescanEveryFrames = 6
    ## While the window is open and the targets are NOT yet resolved, re-scan
    ## the (known!) screen at most this often. ~100 ms. This is a bounded walk
    ## of ONE screen we were HANDED -- never a scene-root enumeration.

# ---- the guarded-body thunk (ONE aowl_p_p_seh, never nested) ----
{.emit: """
extern void* aowl_spl_tick_body(void* a);
static void* aowl_spl_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_spl_tick_body, a);
}
""".}
proc cSplTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_spl_tick_guarded", nodecl.}

# ---- THE PHASE METER (abi/aowlspt_splprof.h) ------------------------------
# Pure C over its own statics; hooks nothing, dereferences nothing, opens NO
# guard. The TOTAL bracket is taken in `splRebrandDrainTick`, strictly OUTSIDE
# `cSplTickGuarded`; every phase bracket is INSIDE the already-open guard and
# opens none of its own. Active only while `drainProfiler` is on.
proc cSpNow(): int64 {.importc: "aowl_sp_now", nodecl.}
proc cSpAdd(slot: int32; t0: int64) {.importc: "aowl_sp_add", nodecl.}
proc cSpCallBegin() {.importc: "aowl_sp_call_begin", nodecl.}
proc cSpCallEnd(t0: int64) {.importc: "aowl_sp_call_end", nodecl.}
proc cSpControl() {.importc: "aowl_sp_control", nodecl.}
proc cSpNs(i: int32): int64 {.importc: "aowl_sp_ns", nodecl.}
proc cSpCalls(i: int32): int64 {.importc: "aowl_sp_calls", nodecl.}
proc cSpMax(i: int32): int64 {.importc: "aowl_sp_max", nodecl.}
proc cSpSubtick(i: int32): int64 {.importc: "aowl_sp_subtick", nodecl.}
proc cSpSlowBy(i: int32): int64 {.importc: "aowl_sp_slow_by", nodecl.}
proc cSpTotalNs(): int64 {.importc: "aowl_sp_total_ns", nodecl.}
proc cSpTotalCalls(): int64 {.importc: "aowl_sp_total_calls", nodecl.}
proc cSpTotalMax(): int64 {.importc: "aowl_sp_total_max", nodecl.}
proc cSpSlowCalls(): int64 {.importc: "aowl_sp_slow_calls", nodecl.}
proc cSpSlowNs(): int64 {.importc: "aowl_sp_slow_ns", nodecl.}
proc cSpSlowUnexp(): int64 {.importc: "aowl_sp_slow_unexp", nodecl.}
proc cSpDropped(): int64 {.importc: "aowl_sp_dropped", nodecl.}
proc cSpSlowThresholdNs(): int64 {.importc: "aowl_sp_slow_ns_threshold", nodecl.}
proc cSpSlots(): int32 {.importc: "aowl_sp_slots", nodecl.}
proc cSpCtrlSlot(): int32 {.importc: "aowl_sp_ctrl_slot", nodecl.}

const
  SpPre     = 0'i32
  SpRoots   = 1'i32
  SpDescend = 2'i32
  SpCheap   = 3'i32
  SpScan    = 4'i32
  SpMHead   = 5'i32
  SpMTog    = 6'i32
  SpMWarn   = 7'i32
  SpDiag    = 8'i32
  SpCtrl    = 9'i32

const SpNames: array[10, string] = [
  "PRE       liveness+staleness checks",
  "ROOTS     scene-root enumeration (the allocating step)",
  "DESCEND   splFindByName under the WIDE, throttled walk",
  "CHEAPHUNT splFindByName under the CACHED UI root (per-frame tier 1)",
  "SCAN      splScanNode, by-text scan inside the screen",
  "MAINT.head  heading + description re-assert",
  "MAINT.tog   practice toggle force + hide",
  "MAINT.warn  co-op warning hide",
  "DIAG      diagnostics + summary string building",
  "CONTROL   positive control (512 dependent adds)"]

# ---- state (gSplOn / gSplForceOffline are set in the flag pass in aowlhost.nim) ----
var gSplOn = false                 ## the `singleplayerRebrand` flag; DEFAULT OFF
var gSplForceOffline = false       ## the `forceOfflinePractice` flag; DEFAULT ON.
                                   ## When set, the practice/offline toggle on the
                                   ## Matchmaker Offline Raid Screen is AUTO-forced
                                   ## ON (Toggle::set_isOn @0x55BA430, fact #71) as
                                   ## soon as the screen appears, so a raid entered
                                   ## by pressing straight through the menus (no
                                   ## manual tick) stays OFFLINE and never enters
                                   ## NetworkGameMatching (fact #263). Independent of
                                   ## the rebrand: it never relabels or hides.
var gSplOff = false                ## self-disabled after faults
var gSplFaults = 0
var gSplT0 = 0'u64
var gSplFrames = 0

var gSplDiagPasses = 0             ## hunt passes since the last diag line (rate limiter)
var gSplLastWhy = ""              ## the last discovery-failure reason we logged
var gSplLastNodes = 0             ## nodes visited on the last screen descent

var gSplScreen: Il2CppPtr = nil    ## the cached "Matchmaker Offline Raid Screen"
                                   ## transform. Cached SEPARATELY from the TMPs
                                   ## so that a rebuild which kills the captions
                                   ## but keeps the screen can be re-scanned from
                                   ## here, without the allocating `iSceneRoots`
                                   ## enumeration. Always liveness-checked before
                                   ## use: a destroyed UnityEngine.Object stays
                                   ## READABLE with m_CachedPtr zeroed (fact
                                   ## #182), so `duOk` alone is not enough and
                                   ## `iUnityAlive` is always asked too.

# ---- THE THIRD CACHE LEVEL: the UI ROOT ("Menu UI"). ----------------------
# MEASURED, by the drain profiler: `splRebrandDrain` averaged 1152.2us/frame
# with a MAX of 194373.3us -- a 194 ms single call, in a rider whose own walk
# carries an 18 ms slice. The slice cannot cover it because `iSceneRoots` runs
# BEFORE the slice starts and takes no deadline at all: it enumerates EVERY
# scene SceneManager lists AND the anchor scene, calling
# `Scene::GetRootGameObjects` (a managed array allocation) per scene and
# `GameObject::get_transform` + klass notes per root. The comment on `splAnchor`
# already records that one of those scenes enumerates 197-274 roots -- and the
# offline-raid screen is in NONE of them. It is in the anchor's own
# DontDestroyOnLoad scene, under "Menu UI".
#
# So the enumeration was paying for every scene in the game to reach one root we
# can name. This caches that root, and its scene handle, and asks Unity for only
# THAT scene when the cache is cold. The cached root is liveness-checked
# (`duOk` + `iUnityAlive`) on every use, exactly like `gSplScreen` -- fact #182
# says a destroyed Object stays readable, so `duOk` alone is not an answer.
var gSplUiRoot: Il2CppPtr = nil    ## the cached "Menu UI" root TRANSFORM
var gSplUiRootName = ""            ## which of the UI roots it is (for the log)
var gSplFullWalks = 0              ## how many FULL (all-scene) enumerations ran
var gSplNarrowWalks = 0            ## how many anchor-scene-only enumerations ran
var gSplUiRootHits = 0             ## hunts that skipped enumeration entirely
var gSplFullWalkAt = 0'u64         ## last full walk, ms -- it is throttled hard
const SplFullWalkEveryMs = 10000'u64
  ## The all-scene enumeration is the 194 ms step. It is kept as a LAST RESORT
  ## -- never removed -- so that if the screen ever moves out of the anchor
  ## scene we still find it; but at most once per this interval, and only after
  ## the narrow path has already failed on the same pass. Removing it would make
  ## "not found" unfalsifiable for a screen that moved.

# ---- the falsifiable flash measurement (CLAUDE.md 9b) ----
# Frames between OBSERVING the stock BSG caption on the live TMP and reading OUR
# caption back off that same TMP. This asserts the FINISHED STATE of the screen,
# not that a setter ran, and it is falsifiable: if the re-assert is slow the
# number is large and the verdict says FAIL.
var gSplScanCut = 0        ## why the last splScanNode stopped: 0 exhaustive,
                           ## 1 node budget, 2 wall-clock, 3 could-not-start,
                           ## 4 depth cap. 0 is the ONLY value that licenses a
                           ## claim that something is absent.
var gSplScanNodes = 0      ## nodes the last scan visited
var gSplScanDeepest = 0    ## deepest BFS level the last scan reached
var gSplHeadDepth = -1     ## MEASURED: BFS level of MainCaption below the screen
var gSplHeadNodes = -1     ## MEASURED: nodes visited before reaching it
var gSplHeadEverResolved = false  ## has the heading TMP EVER been resolved this
                                  ## session? The missing negative: the old
                                  ## acceptance measured how fast we apply ONCE
                                  ## RESOLVED, so it read PASS while the feature
                                  ## never resolved at all.
var gSplUnresolvedRounds = 0      ## consecutive full discovery rounds that ended
                                  ## without a heading TMP
var gSplGaveUpLogged = false
var gSplMeasureLogged = false

const SplUnresolvedFail = 20      ## rounds after which this says FAIL, ONCE

var gSplRescanMisses = 0           ## consecutive fruitless re-scans from the
                                   ## CACHED screen; capped so the cache can
                                   ## never permanently suppress the full walk.
const SplMaxRescanMiss = 20

var gSplStockSeen = false          ## the live heading currently reads stock
var gSplFlashFrames = 0            ## frames counted since gSplStockSeen went true
var gSplEpisodes = 0               ## how many stock->ours transitions we measured
const SplFlashLogMax = 8           ## log at most this many episodes (no spam)

var gSplResolved = false           ## heading TMP found; cache below is trusted
var gSplHeadTmp: Il2CppPtr = nil   ## the "PRACTICE GAME MODE" TMP
var gSplHeadLoc: Il2CppPtr = nil   ## its LocalizedText sibling (optional; nil ok)
var gSplDescTmp: Il2CppPtr = nil   ## the description TMP (optional)
var gSplDescLoc: Il2CppPtr = nil
var gSplCheckGo: Il2CppPtr = nil   ## the SoloModeCheckmarkBlocker GameObject
var gSplToggle: Il2CppPtr = nil    ## the EFT.UI.UpdatableToggle component (a Toggle)
var gSplForceRefused = false       ## set_isOn did not verify; box left VISIBLE
var gSplForceRefusedLogged = false
var gSplWarnGo: Il2CppPtr = nil    ## the co-op/EoD "progress" warning container to hide
var gSplWarnText = ""              ## the matched displayed text (evidence for the readback)
var gSplWarnName = ""              ## name of the node we hide (container or the TMP node)
var gSplWarnMatched = false        ## a valid co-op/progress text match was found this discovery
var gSplWarnRefused = false        ## screen resolved but NO co-op/progress warning matched
var gSplConfirmed = false          ## finished-state assertion has passed+logged
var gSplSummaryLogged = false

# ---- SHOW-EVENT state (see the SplShowWindowFrames banner above) ----
var gSplEventDriven = false        ## the uihooks show hook is BOUND. When true
                                   ## the cadence hunt is never entered, and the
                                   ## boot summary says so.
var gSplWindow = 0                 ## frames of window left; 0 == fully idle
var gSplSettled = 0                ## consecutive frames the readback has held
var gSplOpens = 0                  ## show events we opened a window for
var gSplWindowFramesUsed = 0       ## frames of window actually spent, cumulative

# ---- THE PER-FRAME COST READBACK (CLAUDE.md 9b) ----------------------------
# `gSplNodes` is incremented at the ONE place each walker charges its budget, so
# it counts every live Unity node this feature touched, by construction -- it
# cannot drift from the walkers the way a hand-maintained tally would.
# `splCostLine` divides it by the frames the rider actually saw. BEFORE this
# change that ratio was ~64 nodes per 18 ms slice at ~10 Hz and never fell to
# zero; AFTER, it must fall to zero once every window has closed, and the second
# number below (nodes since the last window closed) is the one that proves it.
var gSplNodes = 0                  ## cumulative live-tree nodes visited, ever
var gSplNodesAtIdle = 0            ## gSplNodes when the last window closed
var gSplTickFrames = 0             ## rider ticks seen (after warm-up)
var gSplWorkFrames = 0             ## rider ticks that entered the guarded body

# ---------------------------------------------------------------------------
# Small guarded primitives, each a thin reuse of an already-verified target.
# ---------------------------------------------------------------------------
var gSplLocStr: Il2CppPtr = nil
proc splLocTypeStr(): Il2CppPtr =
  ## Interned "LocalizedText" for GetComponent. Allocated at most once.
  if gSplLocStr != nil and duOk(gSplLocStr, 0x18'i32):
    return gSplLocStr
  var nm = "LocalizedText"
  gSplLocStr = cNavNewString(toCString(nm))
  result = gSplLocStr

var gSplTogStr: Il2CppPtr = nil
proc splTogTypeStr(): Il2CppPtr =
  ## Interned "UpdatableToggle" for GetComponent (fact #71: the control is
  ## EFT.UI.UpdatableToggle). It derives from UnityEngine.UI.Toggle, so the
  ## returned component is a valid `this` for Toggle::set_isOn and carries
  ## m_IsOn at +0x120.
  if gSplTogStr != nil and duOk(gSplTogStr, 0x18'i32):
    return gSplTogStr
  var nm = "UpdatableToggle"
  gSplTogStr = cNavNewString(toCString(nm))
  result = gSplTogStr

proc splComponent(node, typeStr: Il2CppPtr): Il2CppPtr =
  ## `Component::GetComponent(String)` on a Transform node. Returns nil on any
  ## refusal -- a null is an ANSWER (the component is absent), never a fault.
  result = nil
  if cNavIcallReady() == 0'i32 or typeStr == nil: return
  var fn: Il2CppPtr = nil
  if not iNavFindQuiet("Component::GetComponent(String)", fn) or fn == nil: return
  if not duOk(node, 0x20'i32) or not iUnityAlive(node): return
  iMark("Component::GetComponent(String) [splrebrand]", node)
  let comp = cast[Il2CppPtr](cInspUPP(fn, node, typeStr, nil))
  if comp != nil and duOk(comp, 0xE8'i32) and iUnityAlive(comp):
    result = comp

proc splTmpOf(node: Il2CppPtr): Il2CppPtr =
  ## The TextMeshProUGUI component on a node, BY KLASS IDENTITY.
  ##
  ## This used to be `Component::GetComponent(String)` with the managed string
  ## "TextMeshProUGUI", shared with `findtext`. MEASURED 2026-09-02 on build
  ## 1.1.0.1.46777: that overload returns NULL for every node -- a walk of all
  ## 1263 nodes of an OPEN Settings screen found zero TMP components, while
  ## `label` reads their text fine. So this helper could only ever answer "no
  ## TMP here", whatever the node. It now uses the same `System.Type` findtext
  ## resolves from the OFFLINE name index (no reflection, no allocation).
  ##
  ## PREDICTION, stated rather than assumed: if this path ever appeared to
  ## work, that was not through this call. It is worth re-checking splrebrand
  ## live after this change.
  if not iInspSeedTextType(): return nil
  var why = ""
  let comp = iGetComponentOfType(node, gTmpTypeObj, why)
  if comp != nil and duOk(comp, 0xE8'i32) and iUnityAlive(comp):
    return comp
  result = nil

proc splTmpText(tmp: Il2CppPtr): string =
  ## m_text @0x0E0, decoded by the fixed System.String layout. Guarded exactly
  ## as `findtext` guards it: a KNOWN-KLASS value there is type confusion, not a
  ## String, and must not be read as one.
  result = ""
  if not duOk(tmp, 0xE8'i32): return
  let sp = cReadPtrAt(tmp, 0xE0'i32)
  if sp != nil and not iIsKnownKlass(cast[uint64](sp)) and duOk(sp, 0x18'i32):
    result = suiReadString(sp)

proc splParent(t: Il2CppPtr): Il2CppPtr =
  ## `Transform::get_parent`, guarded. nil on any refusal.
  result = nil
  var idx = 0
  var hits = 0
  if not iFindTarget("Transform::get_parent", idx, hits): return
  let fn = iTargetFn(idx)
  if fn == nil or not iUnityAlive(t): return
  iMark("Transform::get_parent", t)
  let par = cast[Il2CppPtr](cInspUP(fn, t, nil))
  if par != nil and duOk(par, 0x20'i32):
    result = par

proc splSetText(tmp, loc: Il2CppPtr; s: string): bool =
  ## Set TMP text through the REAL setters and re-apply -- the same recipe as
  ## `nuSetText`, inlined here so it does not depend on the `nativeUi` flag.
  ## `ForceMeshUpdate` is deliberately NOT called (0x628110 is the universal
  ## empty stub). The interned string means no per-tick managed allocation.
  let fnSet = nuFn(NuTTmpSetText)
  let str = nuStr(s)
  if fnSet == nil or str == nil or not nuOk(tmp, 0x10'i32): return false
  cNuCallVPP(fnSet, tmp, str)
  if loc != nil and nuOk(loc, 0x10'i32):
    let fnLoc = nuFn(NuTLocSetLabelText)
    if fnLoc != nil:
      cNuCallVPP(fnLoc, loc, str)
      cNuCallVPP(fnSet, tmp, str)          # re-apply after LocalizedText clobber
  result = true

proc splForceToggle(): int =
  ## Force the practice toggle to `SplForceIsOn` via the NOTIFYING setter
  ## `Toggle::set_isOn`, so the game's own onValueChanged listener runs (that
  ## listener is what actually selects the mode -- a raw m_IsOn store would move
  ## the field and NOT run it). Re-asserts once, like a LocalizedText re-apply,
  ## in case something flips it on the same frame. Then reads m_IsOn BACK and
  ## returns the FINISHED STATE, never the fact that the setter ran:
  ##   1 -> readback matches the wanted value (PASS)
  ##   0 -> readback does NOT match (FAIL -- caller must REFUSE to hide)
  ##  -1 -> could not act at all (set_isOn did not verify, or the component is
  ##        unreadable) -- INCONCLUSIVE, caller must REFUSE to hide.
  result = -1
  let fn = cSwFn2(SplToggleSetIsOn)
  if fn == nil:
    if not gSplForceRefusedLogged:
      gSplForceRefusedLogged = true
      warn "singleplayer rebrand: Toggle::set_isOn @0x55BA430 did NOT verify " &
           "against the startup prologue snapshot on this build, so the " &
           "practice toggle CANNOT be forced. REFUSING to hide the checkbox -- " &
           "it is left VISIBLE (and at whatever value the game set) rather than " &
           "hidden with an unknown value. This is a REFUSAL, not a success."
    gSplForceRefused = true
    return
  let off = cSwOffToggleIsOn()
  if not duOk(gSplToggle, off + 8'i32):
    return
  let want = (if SplForceIsOn: 1'i32 else: 0'i32)
  cSwCallVPB2(fn, gSplToggle, want)        # force
  cSwCallVPB2(fn, gSplToggle, want)        # re-assert once
  # READBACK on the finished state. `cSwReadU8` is the guarded byte read.
  let got = cSwReadU8(gSplToggle, off)
  if got == want:
    result = 1
  else:
    result = 0

# ---------------------------------------------------------------------------
# Discovery: bounded, time-sliced.
# ---------------------------------------------------------------------------
const SplMaxRejected = 8

var gSplRejected: seq[Il2CppPtr] = @[]
  ## Nodes that MATCH `SplScreenName` and that an EXHAUSTIVE scan (one that ran
  ## out of neither budget nor time) proved hold no heading TMP.
  ##
  ## This exists because `splFindByName` returns the FIRST node of that name and
  ## there is no guarantee the first one is the right one. Without this ledger a
  ## wrong-but-same-named node is re-found, re-scanned and re-rejected forever,
  ## which is the loop the player sees as "the page is back to vanilla".
  ## ONLY an exhaustive scan may add to it -- a scan that ran out of budget
  ## proved nothing, and entering it here would be a check that cannot fail.
  ## Capped, and cleared whenever the UI root changes, so a rebuilt screen at a
  ## recycled address can never be permanently blacklisted.

proc splRejected(p: Il2CppPtr): bool =
  for i in 0 ..< gSplRejected.len:
    if gSplRejected[i] == p: return true
  false

proc splReject(p: Il2CppPtr) =
  if p == nil or splRejected(p): return
  if gSplRejected.len >= SplMaxRejected: gSplRejected.delete(0)
  gSplRejected.add p

proc splFindByName(t: Il2CppPtr; name: string; depth: int;
                   budget: var int; deadline: uint64;
                   skipRejected = false): Il2CppPtr =
  ## A bounded, TIME-SLICED descent by object name. Three bounds (budget,
  ## in-walk deadline, depth+fan-out), mirroring `mtxDescend`.
  ## BREADTH-BEFORE-DEPTH: at each node we check ALL of its direct children's
  ## names before recursing into any subtree. The target here is a DIRECT child
  ## of the large "UI" root, so a pure DFS would burn the whole budget on the
  ## earlier siblings' (also large) subtrees before ever reaching it -- exactly
  ## the budget-exhaustion that returned nil forever. Checking the sibling names
  ## first reaches a direct child in O(#siblings) nodes, not O(subtree).
  result = nil
  if t == nil or depth < 0 or budget <= 0 or not duOk(t, 0x20'i32): return
  budget = budget - 1
  gSplNodes = gSplNodes + 1            # cost readback; see splScanNode
  if (budget and 31) == 0 and cNowMs() > deadline:
    budget = 0                              # poison the budget: unwinds all levels
    return
  if iObjName(t) == name and not (skipRejected and splRejected(t)):
    return t
  if depth == 0: return
  var n = 0
  if not iChildCount(t, n): return
  # Pass 1 -- breadth: name-check every direct child (cheap; no descent).
  var i = 0
  while i < n and i < SplFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil and duOk(c, 0x20'i32):
      budget = budget - 1
      gSplNodes = gSplNodes + 1        # cost readback; see splScanNode
      if (budget and 31) == 0 and cNowMs() > deadline:
        budget = 0
        return
      if iObjName(c) == name and not (skipRejected and splRejected(c)):
        return c
    i = i + 1
  # Pass 2 -- depth: recurse only after the whole level missed by name.
  i = 0
  while i < n and i < SplFanout and budget > 0:
    let c = iChildAt(t, i)
    if c != nil:
      result = splFindByName(c, name, depth - 1, budget, deadline, skipRejected)
      if result != nil: return
    i = i + 1

proc splAnchor(): Il2CppPtr =
  ## A DURABLE, inspector-independent anchor into the DontDestroyOnLoad scene --
  ## where the live UI (and the "Matchmaker Offline Raid Screen") actually lives,
  ## since SceneManager excludes that scene BY DESIGN (CLAUDE.md 2).
  ##
  ## MEASURED live (inspector `roots`/`find`): the offline-raid screen is a
  ## shallow descendant of "Menu UI" in the DontDestroyOnLoad scene (handle -12,
  ## 22 roots). `gVerPreloader` -- the version-brand's `PreloaderUI::Awake`
  ## `this` -- does NOT belong to that scene: `GameObject::get_scene_Injected`
  ## puts it in a game/environment scene enumerating 197-274 roots, so anchoring
  ## on it made `splFindScreen` walk the WRONG scene and report "NOT found across
  ## 197 roots". The correct object is the `PreloaderUI::Update` `this`, which
  ## DOES land in scene -12. `gSplUpdatePreloader` captures exactly that,
  ## unconditionally, from the shared Update rider block (aowlhost.nim) -- so it
  ## is populated for beta users with liveInspector OFF. `gInspPreloader` is the
  ## same Update `this` but only the inspector writes it; kept as a fallback for
  ## the case where a rider slot has not yet been claimed. `gVerPreloader` is
  ## NO LONGER used as an anchor -- it points at the wrong scene by construction.
  result = nil
  if gSplUpdatePreloader != nil and duOk(gSplUpdatePreloader, 0x20'i32):
    return gSplUpdatePreloader
  if gInspPreloader != nil and duOk(gInspPreloader, 0x20'i32):
    return gInspPreloader

proc splUiRootLive(): Il2CppPtr =
  ## The cached UI root ("Menu UI"), or nil. Liveness-checked every time: a
  ## destroyed UnityEngine.Object stays READABLE with m_CachedPtr zeroed (fact
  ## #182), so `duOk` alone would hand back a corpse.
  result = nil
  if gSplUiRoot == nil: return
  if not duOk(gSplUiRoot, 0x20'i32) or not iUnityAlive(gSplUiRoot):
    gSplUiRoot = nil
    # The menu was torn down. Every rejected-screen pointer belonged to that
    # tree, and a rebuilt screen can land on a recycled address -- so the
    # ledger must die with the root it was measured under. A blacklist that
    # outlives its evidence is a check that cannot fail.
    gSplRejected.setLen(0)
    return
  result = gSplUiRoot

proc splAnchorSceneRoots(roots: var seq[Il2CppPtr]): bool =
  ## THE NARROW ENUMERATION: only the scene our own live anchor belongs to --
  ## the DontDestroyOnLoad scene, which is where the offline-raid screen is and
  ## which SceneManager excludes by design. One `Scene::GetRootGameObjects`,
  ## not one per scene in the game.
  ##
  ## Returns false when it COULD NOT LOOK (no anchor, or Unity would not say
  ## which scene the anchor is in). False is a refusal, never "no roots" --
  ## flattening those two is how a bounded search comes to report a confident
  ## "not present" (CLAUDE.md 9b).
  result = false
  let anchor = splAnchor()
  if anchor == nil: return
  var haveHandle = false
  let ah = iAnchorSceneHandle(haveHandle, anchor)
  if not haveHandle: return
  var bound = 0
  iRootsOfHandle(ah, "", roots, false, bound)
  result = true

proc splFindScreen(): Il2CppPtr =
  ## The "Matchmaker Offline Raid Screen" transform. Reaches DontDestroyOnLoad
  ## via our own durable anchor (NOT the inspector), and gives EACH root the full
  ## node budget (reset per root) so the deep, wide "UI" root is not starved by
  ## whatever was walked before it. Sets `gSplLastWhy`/`gSplLastNodes` so the
  ## caller can log WHY, rate-limited -- a nil here used to be silent, which is
  ## what hid this bug (CLAUDE.md 6/9b).
  ##
  ## THREE COST TIERS, cheapest first. Only the third one is the 194 ms step.
  ##   1. the cached "Menu UI" root is live -> descend from it. NO enumeration,
  ##      no managed allocation, ~100 nodes to a shallow screen.
  ##   2. the anchor's OWN scene only -> one GetRootGameObjects.
  ##   3. every scene (`iSceneRoots`) -> the historical path, now a THROTTLED
  ##      last resort so a screen that moves scenes is still findable.
  result = nil
  gSplLastNodes = 0

  # ---- Tier 1: descend straight from the cached UI root. ----
  let cachedRoot = splUiRootLive()
  if cachedRoot != nil:
    inc gSplUiRootHits
    # Tier 1 runs every frame and carries the SAME bounds as the wide walk, so
    # the two cannot disagree about which node is the screen. Billed to its own
    # phase slot (CHEAPHUNT) so its real cost stays visible and separable from
    # the throttled wide DESCEND. A miss here is NOT a verdict of absence -- it
    # falls through below.
    var budget = SplNodeBudget
    let dl = cNowMs() + SplCheapMs
    let tD = cSpNow()
    let m = splFindByName(cachedRoot, SplScreenName, SplFindDepth, budget, dl,
                          skipRejected = true)
    cSpAdd(SpCheap, tD)
    gSplLastNodes = gSplLastNodes + (SplNodeBudget - budget)
    if m != nil:
      gSplLastWhy = ""
      return m
    # Not under the cached root THIS pass. That is the normal answer while the
    # offline-raid screen is closed, so it is NOT a reason to drop the cache --
    # dropping it would put us back on the expensive path every pass.
    gSplLastWhy = "screen \"" & SplScreenName & "\" is not under the cached UI " &
      "root \"" & gSplUiRootName & "\" (" & $gSplLastNodes & " nodes, depth " &
      $SplFindDepth & ", " & $int(SplCheapMs) & " ms slice" &
      (if gSplRejected.len > 0: ", skipping " & $gSplRejected.len &
         " node(s) of that name already proven to hold no heading" else: "") &
      "). Normal while the offline-raid screen is not open."
    # Fall through to a wider look only when the expensive path is due. Stamp
    # the clock HERE, on the decision to go wide -- not inside tier 3, which
    # normally does not run at all once tier 2 returns roots. Stamping only in
    # tier 3 would leave this test true on every pass and hand back the
    # per-frame enumeration this change exists to remove.
    if cNowMs() - gSplFullWalkAt < SplFullWalkEveryMs:
      return
    gSplFullWalkAt = cNowMs()

  let anchor = splAnchor()
  var roots: seq[Il2CppPtr] = @[]

  # ---- Tier 2: the anchor's own scene only. ----
  let tR = cSpNow()
  let narrowOk = splAnchorSceneRoots(roots)
  if narrowOk: inc gSplNarrowWalks
  # ---- Tier 3: every scene -- the 194 ms step, throttled, never removed. ----
  # Escalate when the narrow scene gave NOTHING, or when it gave roots but none
  # of them was a UI root -- otherwise a screen that moved to another scene
  # would be permanently unfindable and "not found" would stop being falsifiable.
  if (roots.len == 0 or gSplUiRoot == nil) and
     cNowMs() - gSplFullWalkAt >= SplFullWalkEveryMs:
    gSplFullWalkAt = cNowMs()
    inc gSplFullWalks
    roots.setLen(0)          # iSceneRoots enumerates the anchor scene too
    discard iSceneRoots(roots, false, anchor)
  cSpAdd(SpRoots, tR)
  if roots.len == 0:
    # THREE OUTCOMES, never two: no anchor / could-not-look / looked-and-empty.
    gSplLastWhy = (if anchor == nil:
      "no roots, and this feature has no durable anchor yet " &
      "(gSplUpdatePreloader/gInspPreloader both null). This resolves once a " &
      "PreloaderUI::Update rider slot has been claimed and the menu is ticking " &
      "-- independent of liveInspector."
      elif not narrowOk:
      "I COULD NOT LOOK: there IS a durable anchor, but " &
      "GameObject::get_scene_Injected would not say which scene it is in, so " &
      "the anchor-scene enumeration never ran. This is a REFUSAL, not " &
      "\"no roots\"."
      else:
      "the anchor's own scene enumerated ZERO roots -- the menu is likely not " &
      "up yet.")
    return
  let deadline = cNowMs() + SplWalkMs
  # Pass 1 -- the UI-bearing roots BY NAME ("Menu UI"/"Common UI"), where the
  # screen actually is. This is the fix: a plain 0..N walk let the giant early
  # roots ("Application (Main Client)") consume the whole 18ms slice before
  # reaching "Menu UI" (~root #20), so the screen was NEVER found though it was
  # present. Searching the UI roots first reaches it with budget to spare.
  var dbgRoots = ""
  var dbgUiMatched = 0
  # Search the UI roots in PRIORITY ORDER: "Menu UI" FIRST (that is where the
  # offline-raid screen lives, measured: Menu UI -> UI -> screen, depth 2), THEN
  # "Common UI". The shared 18ms deadline was being consumed by "Common UI"
  # (which precedes "Menu UI" in the root list and is a large tree) before
  # "Menu UI" was ever reached -- so the screen, though shallow, was never found
  # (diag: UI-roots matched=1, 24001 nodes). A named priority order fixes it:
  # Menu UI is searched first and the shallow screen is found in ~100 nodes.
  for want in [SplUiRoot0, SplUiRoot1]:
    var i = 0
    while i < roots.len:
      let r = iToTransform(roots[i])
      if r != nil and duOk(r, 0x20'i32):
        let nm = iObjName(r)
        if want == SplUiRoot0 and dbgRoots.len < 400:
          dbgRoots = dbgRoots & "[" & nm & "]"      # dump once, on the first pass
        if nm == want:
          dbgUiMatched = dbgUiMatched + 1
          # CACHE THE UI ROOT. This is the whole point of the change: every
          # later hunt starts here and never enumerates a scene again while
          # this root is alive. It is re-validated (duOk + iUnityAlive) on
          # every use by `splUiRootLive`, so a menu teardown drops it and the
          # enumeration comes back -- the cache cannot outlive its object.
          if want == SplUiRoot0 or gSplUiRoot == nil:
            gSplUiRoot = r
            gSplUiRootName = nm
          var budget = SplNodeBudget
          let tD2 = cSpNow()
          let m = splFindByName(r, SplScreenName, SplFindDepth, budget, deadline)
          cSpAdd(SpDescend, tD2)
          gSplLastNodes = gSplLastNodes + (SplNodeBudget - budget)
          if m != nil:
            gSplLastWhy = ""
            return m
      if cNowMs() > deadline: break
      i = i + 1
    if cNowMs() > deadline: break
  # Pass 2 -- fallback: every other root, in case the screen ever moves.
  var i = 0
  while i < roots.len:
    let r = iToTransform(roots[i])
    if r != nil and duOk(r, 0x20'i32):
      let nm = iObjName(r)
      if nm != SplUiRoot0 and nm != SplUiRoot1:
        var budget = SplNodeBudget                 # per-ROOT budget, reset each root
        let tD3 = cSpNow()
        let m = splFindByName(r, SplScreenName, SplFindDepth, budget, deadline)
        cSpAdd(SpDescend, tD3)
        gSplLastNodes = gSplLastNodes + (SplNodeBudget - budget)
        if m != nil:
          gSplLastWhy = ""
          return m
    if cNowMs() > deadline: break
    i = i + 1
  gSplLastWhy = "screen \"" & SplScreenName & "\" NOT found across " &
    $roots.len & " root(s) with a per-root budget of " & $SplNodeBudget &
    " (" & $gSplLastNodes & " nodes visited, " & $int(SplWalkMs) &
    " ms slice; UI-roots matched=" & $dbgUiMatched & "; roots=" & dbgRoots &
    "). Normal when the offline-raid screen is not open; if it IS " &
    "open and this persists, raise the budget or the slice."

proc splIsCoopWarn(low: string): bool =
  ## True only for the co-op / Edge-of-Darkness "your progress is not saved/
  ## shared" warning. Requires "progress" AND a corroborating token, and hard-
  ## EXCLUDES the weapon warning ("...your weapon doesn't have the required
  ## vital part") so it can never hide the wrong node. `low` is already lowered.
  if not iContains(low, SplWarnStock): return false
  if iContains(low, SplWarnExclA) or iContains(low, SplWarnExclB): return false
  result = iContains(low, "not") or iContains(low, "co-op") or
           iContains(low, "coop") or iContains(low, "shared") or
           iContains(low, "saved") or iContains(low, "edge of darkness")

proc splWarnContainer(t: Il2CppPtr; nameOut: var string): Il2CppPtr =
  ## Climb up to `SplWarnUp` levels toward the warning-panel container and return
  ## its GameObject, mirroring the SoloModeCheckmarkBlocker climb. Falls back to
  ## the matched TMP node's OWN GameObject if no named panel is found -- so it
  ## always hides the matched warning, never a random sibling. Every hop guarded.
  result = nil
  nameOut = ""
  # default target: the matched node's own GameObject (hides at least the line).
  let selfGo = iGameObjectOf(t)
  if selfGo != nil and duOk(selfGo, 0x20'i32):
    result = selfGo
    nameOut = iObjName(t)
  var up = t
  var k = 0
  while k < SplWarnUp and up != nil and duOk(up, 0x20'i32):
    let low = iLower(iObjName(up))
    if iContains(low, "warn") or iContains(low, "progress") or
       iContains(low, "panel"):
      let go = iGameObjectOf(up)
      if go != nil and duOk(go, 0x20'i32):
        result = go
        nameOut = iObjName(up)
      break
    up = splParent(up)
    k = k + 1

proc splScanOne(t: Il2CppPtr) =
  ## Read ONE node's TMP text and, by CONTENT, fill whichever target it is.
  let tmp = splTmpOf(t)
  if tmp == nil: return
  let low = iLower(splTmpText(tmp))
  if low.len == 0: return
  if gSplHeadTmp == nil and iContains(low, SplHeadStock):
    gSplHeadTmp = tmp
    gSplHeadLoc = splComponent(t, splLocTypeStr())
  elif gSplDescTmp == nil and iContains(low, SplDescStock):
    gSplDescTmp = tmp
    gSplDescLoc = splComponent(t, splLocTypeStr())
  elif gSplCheckGo == nil and iContains(low, SplToggleStock):
    # Climb to the SoloModeCheckmarkBlocker and take BOTH its GameObject
    # (to hide) and its UpdatableToggle component (to force ON, fact #71).
    var up = t
    var k = 0
    while k < SplBlockerUp and up != nil:
      if iObjName(up) == SplBlockerName:
        let go = iGameObjectOf(up)
        if go != nil and duOk(go, 0x20'i32):
          gSplCheckGo = go
        let tog = splComponent(up, splTogTypeStr())
        if tog != nil and duOk(tog, cSwOffToggleIsOn() + 8'i32):
          gSplToggle = tog
        break
      up = splParent(up)
      k = k + 1
  # The co-op / EoD "progress is not saved/shared" warning is an INDEPENDENT
  # target (its text collides with none of the three above), so this is its own
  # check, not part of the elif chain. Matched by content, weapon warning
  # excluded, container taken by climbing like the checkbox blocker.
  if gSplWarnGo == nil and splIsCoopWarn(low):
    var wn = ""
    let wg = splWarnContainer(t, wn)
    if wg != nil:
      gSplWarnGo = wg
      gSplWarnText = low
      gSplWarnName = wn
      gSplWarnMatched = true

proc splScanNode(t: Il2CppPtr; depth: int; budget: var int; deadline: uint64) =
  ## Find the targets by CONTAINER NAME within the screen -- cheap name-reads
  ## with early-return, not a TMP-text read of every node (which timed out on the
  ## ~494-node subtree). Names measured live inside this screen:
  ##   heading  -> "MainCaption"              (its TMP text is "Practice game mode")
  ##   checkbox -> "SoloModeCheckmarkBlocker" (GameObject to hide + Toggle to force)
  ##   warning  -> "WarningTextVertLayout"    (GameObject to hide)
  ## The description is a LocalizedText whose m_text does not contain the visible
  ## words, so it is intentionally NOT relabelled here (a known gap; the heading,
  ## checkbox and warning are what the player reacts to).
  ## TRUE level-order BFS matching NAMES. splFindByName is per-node
  ## breadth-then-DFS: it found the shallow SCREEN fine, but the targets are
  ## ~3-4 levels down, so it recursed depth-first into the deep settings subtree
  ## and the 18 ms slice expired before reaching CaptionsHolder. A real BFS
  ## visits every depth-1 node, then every depth-2, etc., so the shallow targets
  ## are reached before the deep settings. Name-reads (not TMP reads) keep each
  ## node cheap; early-out the moment all three are in hand.
  ## THREE OUTCOMES, and the caller must be able to tell them apart:
  ##   * found what it needed                      -> gSplScanCut = 0
  ##   * ran the WHOLE subtree and it is not there -> gSplScanCut = 0, exhaustive
  ##   * ran out of node budget or wall-clock      -> gSplScanCut = 1 or 2
  ## Collapsing the last two into "not resolved" is what let a bound that was
  ## simply too small read exactly like a screen that genuinely has no heading.
  gSplScanCut = 0
  gSplScanNodes = 0
  gSplScanDeepest = 0
  let budget0 = budget
  if t == nil or depth < 0 or budget <= 0 or not duOk(t, 0x20'i32):
    gSplScanCut = 3                       # could not even start -- INCONCLUSIVE
    return
  var frontier: seq[Il2CppPtr] = @[t]
  var d = 0
  while frontier.len > 0 and d <= depth and budget > 0:
    gSplScanDeepest = d
    var nextf: seq[Il2CppPtr] = @[]
    var fi = 0
    while fi < frontier.len and budget > 0:
      let node = frontier[fi]
      fi = fi + 1
      if node == nil or not duOk(node, 0x20'i32): continue
      budget = budget - 1
      gSplNodes = gSplNodes + 1        # the cost readback -- charged HERE, at
                                       # the one place a node is spent, so it
                                       # cannot drift from the walk.
      gSplScanNodes = budget0 - budget
      if (budget and 31) == 0 and cNowMs() > deadline:
        budget = 0
        gSplScanCut = 2                   # CUT OFF BY THE CLOCK
        return
      let nm = iObjName(node)
      if gSplHeadTmp == nil and nm == SplHeadNode:
        let tmp = splTmpOf(node)
        if tmp != nil:
          gSplHeadTmp = tmp
          gSplHeadLoc = splComponent(node, splLocTypeStr())
          # THE MEASUREMENT. How far the heading actually is from the screen
          # root, in BFS levels and in nodes visited. Every bound in this file
          # that used to be a guess is now sized against these two numbers, and
          # they are logged once so they can be argued with.
          gSplHeadDepth = d
          gSplHeadNodes = gSplScanNodes
      elif gSplDescTmp == nil and nm == SplDescNode:
        let tmp = splTmpOf(node)
        if tmp != nil:
          gSplDescTmp = tmp
          gSplDescLoc = splComponent(node, splLocTypeStr())
      elif gSplCheckGo == nil and nm == SplBlockerName:
        let go = iGameObjectOf(node)
        if go != nil and duOk(go, 0x20'i32):
          gSplCheckGo = go
        let tog = splComponent(node, splTogTypeStr())
        if tog != nil and duOk(tog, cSwOffToggleIsOn() + 8'i32):
          gSplToggle = tog
      elif gSplWarnGo == nil and nm == SplWarnNode:
        let go = iGameObjectOf(node)
        if go != nil and duOk(go, 0x20'i32):
          gSplWarnGo = go
          gSplWarnName = SplWarnNode
          gSplWarnMatched = true
      if gSplHeadTmp != nil and gSplCheckGo != nil and gSplWarnGo != nil:
        return
      var n = 0
      if iChildCount(node, n):
        var i = 0
        while i < n and i < SplFanout:
          let c = iChildAt(node, i)
          if c != nil: nextf.add c
          i = i + 1
    frontier = nextf
    d = d + 1
  # Fell out of the loop. Say WHICH bound ended it -- an empty frontier means
  # the subtree was searched EXHAUSTIVELY and the target is genuinely absent,
  # which is a completely different claim from running out of room.
  if budget <= 0: gSplScanCut = 1         # CUT OFF BY THE NODE BUDGET
  elif frontier.len > 0 and d > depth: gSplScanCut = 4  # CUT OFF BY THE DEPTH CAP

# ---------------------------------------------------------------------------
# Maintain + assert the FINISHED STATE (never our own write -- fact #9b).
# ---------------------------------------------------------------------------
proc splCacheStale(): bool =
  ## The screen can be destroyed (navigate away) and rebuilt; the cached
  ## pointers then read a dead object. If the heading TMP is gone, drop the
  ## whole cache and re-discover.
  gSplHeadTmp == nil or not duOk(gSplHeadTmp, 0xE8'i32) or
    not iUnityAlive(gSplHeadTmp)

var gSplHeadStrOk: Il2CppPtr = nil   ## the LAST System.String pointer read out of
                                     ## gSplHeadTmp.m_text that DECODED to our own
                                     ## caption. See splTextIsOurs.
var gSplDescStrOk: Il2CppPtr = nil
var gSplLatchHits = 0                ## frames the latch answered without decoding
var gSplLatchMiss = 0                ## frames it had to decode

proc splTextIsOurs(tmp: Il2CppPtr; wantLow: string; latch: var Il2CppPtr): bool =
  ## "Does this TMP currently render OUR caption?" -- answered, in the steady
  ## state, by ONE guarded pointer read instead of a string decode plus two
  ## whole-string allocations (`iLower`, `iContains`).
  ##
  ## WHY THIS IS SOUND, and it is the only reason it is allowed: `m_text` holds
  ## a MANAGED System.String REFERENCE. `LocalizedText`'s clobber and
  ## `TMP_Text::set_text` both STORE A DIFFERENT STRING OBJECT there; neither
  ## mutates the one already present (System.String is immutable in the CLR and
  ## IL2CPP keeps that). So an UNCHANGED pointer means an unchanged rendered
  ## caption. The latch therefore accelerates the CHECK; it does NOT skip the
  ## re-apply -- the instant anything writes m_text the pointer differs, the
  ## latch misses, the full decode runs and the re-apply happens on that frame.
  ##
  ## THREE OUTCOMES. The latch can only ever answer TRUE-FAST. A miss falls all
  ## the way through to the real decode; there is no fast "no". A check that
  ## cannot fail would be one that also short-circuited the negative.
  result = false
  if not duOk(tmp, 0xE8'i32):
    latch = nil
    return
  let sp = cReadPtrAt(tmp, 0xE0'i32)
  if sp == nil:
    latch = nil
    return
  if sp == latch:
    inc gSplLatchHits
    return true                       # same String object => same rendered text
  inc gSplLatchMiss
  latch = nil
  if iIsKnownKlass(cast[uint64](sp)) or not duOk(sp, 0x18'i32): return
  if iContains(iLower(suiReadString(sp)), wantLow):
    latch = sp                        # remember the object that reads as ours
    result = true

proc splMaintain() =
  ## Two independent jobs, each gated by its own flag:
  ##   * forceOfflinePractice (gSplForceOffline): keep the practice/offline
  ##     toggle forced ON so a raid stays offline (fact #263/#71). Box left
  ##     VISIBLE and ticked -- no relabel, no hide.
  ##   * singleplayerRebrand (gSplOn): relabel the heading/description, force the
  ##     toggle ON and then HIDE the checkbox, and hide the co-op warning.
  ## Then, ONCE, assert the FINISHED STATE and log PASS/FAIL/INCONCLUSIVE.

  # ---- Heading + description: the REBRAND only. ----
  var headOk = false
  var descState = 2   # 0 FAIL, 1 PASS, 2 INCONCLUSIVE (not found / not wanted)
  let tMH = cSpNow()
  if gSplOn:
    if splTextIsOurs(gSplHeadTmp, SplHeadNewLow, gSplHeadStrOk):
      headOk = true
      # ---- the flash window CLOSED. Report it, and judge it. ----
      if gSplStockSeen:
        gSplStockSeen = false
        inc gSplEpisodes
        if gSplEpisodes <= SplFlashLogMax:
          let verdict = (if gSplFlashFrames <= 2: "PASS"
                         elif gSplFlashFrames >= 6: "FAIL"
                         else: "INCONCLUSIVE")
          okLog "singleplayer rebrand: frames-to-apply=" & $gSplFlashFrames &
                " verdict " & verdict & " (episode " & $gSplEpisodes &
                "). Frames between the live heading TMP reading BSG's stock " &
                "caption and that SAME TMP reading ours back. PASS <=2 (no " &
                "visible flash), FAIL >=6 (the player sees vanilla text), " &
                "INCONCLUSIVE between. This reads the finished state of the " &
                "rendered tree, not that a setter was called."
    else:
      if not gSplStockSeen:
        gSplStockSeen = true          # the window OPENS here; the drain tick counts
        gSplFlashFrames = 0
      gSplHeadStrOk = nil
      discard splSetText(gSplHeadTmp, gSplHeadLoc, SplHeadNew)
    if gSplDescTmp != nil and duOk(gSplDescTmp, 0xE8'i32) and iUnityAlive(gSplDescTmp):
      if splTextIsOurs(gSplDescTmp, SplDescNewLow, gSplDescStrOk):
        descState = 1
      else:
        gSplDescStrOk = nil
        discard splSetText(gSplDescTmp, gSplDescLoc, SplDescNew)
        descState = 0
  cSpAdd(SpMHead, tMH)

  # ---- Practice toggle: FORCE ON whenever EITHER feature is active (the offline
  # mechanism -- the notifying `set_isOn` runs while the GameObject is ACTIVE so
  # the game's onValueChanged listener, which selects the mode, fires). HIDE the
  # checkbox ONLY for the rebrand; forceOfflinePractice leaves the (now ticked)
  # box VISIBLE so the user can see practice mode is on.
  var forceState = 2   # 2 INCONCLUSIVE/REFUSED, 1 PASS (readback == wanted), 0 FAIL
  var hideState  = 2   # 2 INCONCLUSIVE/REFUSED/not-wanted, 1 PASS (hidden), 0 acting
  let wantOn = (if SplForceIsOn: 1'i32 else: 0'i32)
  let tMT = cSpNow()
  if (gSplForceOffline or gSplOn) and
     gSplToggle != nil and duOk(gSplToggle, cSwOffToggleIsOn() + 8'i32) and
     gSplCheckGo != nil and duOk(gSplCheckGo, 0x20'i32) and iUnityAlive(gSplCheckGo):
    # ONE activeInHierarchy call per pass, not three. It is an IL2CPP
    # internal-call wrapper into Unity C++; the steady state asked the SAME
    # question up to three times per frame and used the third answer to judge
    # the first. Re-read ONLY after we act, so the readback still describes the
    # FINISHED STATE and not the intent (9b).
    var boxActive = nuActiveInHierarchy(gSplCheckGo)
    if boxActive:
      discard splForceToggle()              # forces set_isOn (sets gSplForceRefused if the RVA is UNVERIFIED)
      # Hide once set_isOn was actually CALLED. fact #71: Toggle::set_isOn
      # @0x55BA430 DOES tick this UpdatableToggle (human-confirmed on screen), so
      # a verified RVA means the value was applied AND the onValueChanged listener
      # fired -- we do NOT gate the hide on the m_IsOn readback, whose offset is
      # unreliable for UpdatableToggle (it read FAIL while the box visibly ticks).
      # Offline is decided by the emulated backend, not by this client checkbox,
      # so hiding a correctly-forced box cannot strand us online. Only if the RVA
      # itself could not be verified (gSplForceRefused) is the box left visible,
      # and hiding is a REBRAND concern only.
      if gSplOn and not gSplForceRefused:
        discard nuSetActive(gSplCheckGo, false)
        boxActive = nuActiveInHierarchy(gSplCheckGo)   # re-read AFTER acting
    # Assert the FINISHED STATE of the FORCE (both features care about this).
    if not gSplForceRefused:
      forceState = (if cSwReadU8(gSplToggle, cSwOffToggleIsOn()) == wantOn: 1 else: 0)
    # The HIDE finished-state is a rebrand-only assertion.
    if gSplOn:
      if gSplForceRefused:
        hideState = 2                        # could not force -> box left VISIBLE
      elif not boxActive:
        hideState = 1
      else:
        hideState = 0
  cSpAdd(SpMTog, tMT)

  # ---- Co-op / Edge-of-Darkness "progress is not saved/shared" warning: the
  # REBRAND only -- hide the whole container (content-discovery + SetActive, no
  # write into game code). Assert activeInHierarchy == false, not that SetActive
  # was called. If the screen resolved but nothing matched the co-op/progress
  # predicate, REFUSE -- never hide a random node.
  var warnState = 3   # 3 not-found-yet, 2 REFUSED, 1 PASS (hidden), 0 acting/FAIL
  let tMW = cSpNow()
  if gSplOn:
    if gSplWarnGo != nil and duOk(gSplWarnGo, 0x20'i32) and iUnityAlive(gSplWarnGo):
      # Same single-read discipline as the checkbox above: ask once, act only if
      # needed, and re-ask ONLY after acting so the verdict is still a readback
      # of the finished state rather than of our intent.
      var warnActive = nuActiveInHierarchy(gSplWarnGo)
      if warnActive:
        discard nuSetActive(gSplWarnGo, false)
        warnActive = nuActiveInHierarchy(gSplWarnGo)
      warnState = (if not warnActive: 1 else: 0)
    elif not gSplWarnMatched:
      gSplWarnRefused = true
      warnState = 2
  cSpAdd(SpMWarn, tMW)

  # ---- Finished-state summary, once. Ready when each ACTIVE feature has acted:
  # the rebrand once its heading has taken; forceOfflinePractice once the toggle
  # force has a readback (or refused, which is announced separately). ----
  let tMD = cSpNow()
  let forceStr = (case forceState
    of 1: "PASS"
    of 0: "FAIL"
    else: (if gSplForceRefused: "REFUSED (set_isOn @0x55BA430 did not verify)"
           else: "INCONCLUSIVE (no toggle found)"))
  let readyToLog = ((not gSplOn) or headOk) and
                   ((not gSplForceOffline) or forceState != 2 or gSplForceRefused)
  if readyToLog and not gSplSummaryLogged:
    let onWord = (if SplForceIsOn: "true" else: "false")
    # THE forceOfflinePractice MARKER the coordinator watches for.
    if gSplForceOffline:
      okLog "singleplayer: forceOfflinePractice -- practice/offline toggle " &
            "forced isOn=" & onWord & ": " & forceStr & ". This is the offline " &
            "mechanism (fact #263/#71): a raid entered from here does NOT enter " &
            "NetworkGameMatching. NOTE: whether checked==offline is UNCONFIRMED " &
            "on this build; if a live raid comes up ONLINE after this, flip " &
            "SplForceIsOn, do not re-derive the plumbing."
    if gSplOn:
      let hideStr = (case hideState
        of 1: "PASS"
        of 0: "acting (SetActive(false) issued; confirm next tick)"
        else: (if gSplForceRefused:
                 "REFUSED (set_isOn did not verify -- box left VISIBLE)"
               elif forceState == 0:
                 "REFUSED (isOn readback did not match -- box left VISIBLE)"
               else: "INCONCLUSIVE (no practice checkbox found)"))
      okLog "singleplayer: hide: " & hideStr
      let warnStr = (case warnState
        of 1: "PASS"
        of 0: "FAIL (SetActive(false) issued but node still activeInHierarchy)"
        of 2: "REFUSED (no co-op/progress warning matched on this screen -- " &
              "nothing hidden; the weapon \"vital part\" warning is excluded)"
        else: "INCONCLUSIVE (warning not present yet)")
      let warnEvidence = (if gSplWarnMatched:
        " (matched text contains \"progress\"+co-op token, weapon warning " &
        "excluded; hid container \"" & gSplWarnName & "\")"
        else: "")
      okLog "singleplayer: coop-warning hidden " & warnStr & warnEvidence
      let descStr = (case descState
        of 1: "PASS"
        of 0: "FAIL (re-applying)"
        else: "INCONCLUSIVE (no description TMP found)")
      okLog "singleplayer rebrand: FINISHED-STATE readback -- heading: PASS " &
            "(the rendered TMP no longer reads \"PRACTICE GAME MODE\"); " &
            "description: " & descStr & "; forced isOn: " & forceStr &
            "; hide: " & hideStr & "; coop-warning: " & warnStr &
            ". This asserts the live tree, not that a setter ran."
    gSplSummaryLogged = true
    var confirmed = true
    if gSplOn and not (headOk and descState != 0 and hideState == 1 and warnState != 0):
      confirmed = false
    if gSplForceOffline and forceState != 1:
      confirmed = false
    gSplConfirmed = confirmed
  cSpAdd(SpDiag, tMD)

# ---------------------------------------------------------------------------
# The guarded body + the drain rider.
# ---------------------------------------------------------------------------
var gSplLastWhyLogged = ""

## Carried from the show-event postfix into the guarded body. `cSplTickGuarded`
## takes no argument, and `aowl_p_p_seh` is not re-entrant, so the receiver is
## parked here rather than opening a second guard to pass it.
var gSplShowSelf: Il2CppPtr = nil
var gSplShowPending = false

proc splResetTargets() =
  ## Drop every cached target. Called when the screen is (re)built -- from the
  ## staleness check and from a fresh show event. `gSplScreen` is NOT touched
  ## here: the caller decides where the next screen comes from.
  gSplResolved = false
  gSplHeadTmp = nil; gSplHeadLoc = nil
  gSplDescTmp = nil; gSplDescLoc = nil
  # The TMPs are going, so the String-identity latches must go with them, or a
  # recycled address could answer for a caption we never checked.
  gSplHeadStrOk = nil; gSplDescStrOk = nil
  gSplCheckGo = nil
  gSplToggle = nil
  gSplForceRefused = false
  gSplWarnGo = nil; gSplWarnText = ""; gSplWarnName = ""
  gSplWarnMatched = false; gSplWarnRefused = false
  gSplConfirmed = false
  gSplSummaryLogged = false

proc splDiag(reason: string) =
  ## Rate-limited "why discovery has not fired" line. Logs when the reason
  ## CHANGES, or at most once per ~30 hunt passes (~30 s), so a failure path can
  ## no longer decline silently (CLAUDE.md 6) without spamming the log.
  if reason.len == 0: return
  inc gSplDiagPasses
  if reason != gSplLastWhyLogged or gSplDiagPasses >= 30:
    gSplDiagPasses = 0
    gSplLastWhyLogged = reason
    warn "singleplayer rebrand: not resolved -- " & reason

proc splRebrandTickBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_spl_tick_body", cdecl.} =
  ## Everything that touches managed memory, under ONE guard. Returns a non-nil
  ## sentinel on clean completion; the guard returns nil if this faulted.
  result = cast[Il2CppPtr](1)
  discard a
  # THE POSITIVE CONTROL, in the same call, on the same clock, through the same
  # bracket. Its printed cost is what rules out "the meter is lying".
  cSpControl()
  let tPre = cSpNow()

  # The cached SCREEN is validated on its own, every pass, before anything is
  # allowed to reuse it. `duOk` is not sufficient: a destroyed UnityEngine.Object
  # remains readable with m_CachedPtr zeroed (fact #182) and the next internal
  # call dies inside Unity's C++, so liveness is asked explicitly.
  if gSplScreen != nil and
     (not duOk(gSplScreen, 0x20'i32) or not iUnityAlive(gSplScreen)):
    gSplScreen = nil

  # ---- A FRESH SHOW EVENT, handed to us by uihooks. ----
  # `iToTransform` is an ICALL into Unity, so it belongs INSIDE this guard and
  # not in the postfix that parked the pointer. It returns its argument
  # unchanged when the lookup fails, so the result is liveness-checked before it
  # is believed -- a screen we cannot get a Transform for is a refusal, not a
  # silently-wrong root.
  if gSplShowPending:
    gSplShowPending = false
    let self = gSplShowSelf
    gSplShowSelf = nil
    var t: Il2CppPtr = nil
    if self != nil and duOk(self, 0x20'i32) and iUnityAlive(self):
      let cand = iToTransform(self)
      if cand != nil and cand != self and duOk(cand, 0x20'i32) and
         iUnityAlive(cand):
        t = cand
    if t == nil:
      gSplWindow = 0
      warn "singleplayer rebrand: the show event fired but " &
           "Component::get_transform did not yield a live Transform for the " &
           "screen (RCX=0x" & hexOf(cast[uint64](self)) & "). NOTHING was " &
           "walked and NOTHING was written -- this is a refusal, not a miss. " &
           "The next open will try again."
    else:
      gSplScreen = t
      splResetTargets()

  if gSplResolved and splCacheStale():
    # The screen went away and came back (or was rebuilt). Re-discover from
    # scratch rather than writing into a dead object. `gSplScreen` is NOT dropped
    # here -- if the screen object itself survived the rebuild (only its children
    # were replaced) we re-scan from it directly.
    splResetTargets()

  cSpAdd(SpPre, tPre)

  if not gSplResolved:
    # Reuse the validated screen when we have one; only walk the scene roots when
    # we do not. The walk is the allocating step and the reason discovery was
    # ever throttled.
    var screen = gSplScreen
    let reusedScreen = screen != nil
    if screen == nil and gSplEventDriven:
      # EVENT-DRIVEN: the screen only ever comes from the show hook. There is
      # deliberately NO fallback to `splFindScreen` here -- that is the cadence
      # walk this change exists to delete, and re-entering it "just in case"
      # would restore the exact per-frame cost the user objected to. Close the
      # window; the next open re-arms us.
      gSplWindow = 0
      return
    if screen == nil:
      # LEGACY path, reached ONLY when the show hook did not bind (a prologue
      # mismatch or a build difference). `bindSplShowHook` says so loudly at
      # boot; this is the announced fallback, not a silent one.
      # splFindScreen brackets its OWN phases (ROOTS / DESCEND) internally, so
      # the decomposition stays disjoint: no bracket here would double-count.
      screen = splFindScreen()
    if screen == nil:
      let tG0 = cSpNow()
      splDiag(gSplLastWhy)                # announce WHY, rate-limited (was silent)
      cSpAdd(SpDiag, tG0)
      return
    gSplScreen = screen
    # A cached screen that keeps yielding nothing must NOT lock us out of the
    # full walk for the session -- that would be a check that cannot fail. After
    # a capped number of fruitless re-scans the cache is dropped and the next
    # pass does the real root enumeration again.
    if reusedScreen and not gSplEventDriven:
      # LEGACY ONLY. The re-scan ledger exists because the cadence hunt could
      # find the WRONG node of that name and then re-scan it forever. In
      # event-driven mode the game HANDED us this object as the screen it just
      # showed, so "the scan found nothing yet" means the screen is still
      # building -- dropping it and re-walking the scene roots would be exactly
      # the wrong inference, and would re-enter the walk this change deletes.
      inc gSplRescanMisses
      if gSplRescanMisses > SplMaxRescanMiss:
        gSplRescanMisses = 0
        gSplScreen = nil
        let tG1 = cSpNow()
        splDiag("the CACHED \"" & SplScreenName & "\" yielded no targets on " &
          $SplMaxRescanMiss & " consecutive re-scans; dropping the cached " &
          "screen and re-walking the scene roots.")
        cSpAdd(SpDiag, tG1)
        return
    else:
      gSplRescanMisses = 0
    var budget = SplNodeBudget
    let deadline = cNowMs() + SplWalkMs
    let tS = cSpNow()
    splScanNode(screen, SplScanDepth, budget, deadline)
    cSpAdd(SpScan, tS)
    # Resolve only once every ACTIVE feature has the target it needs: the rebrand
    # needs the heading TMP, forceOfflinePractice needs the UpdatableToggle. A
    # missing one is "screen still building", not a failure -- retry.
    if gSplOn and gSplHeadTmp == nil:
      let tG2 = cSpNow()
      inc gSplUnresolvedRounds
      # THE TWO FAILURE MODES, which used to share one sentence. They have
      # different causes and different fixes, and saying "not read within
      # budget" for both is what let a bound that was simply too small look
      # exactly like a screen that has no heading.
      let where = "node \"" & SplHeadNode & "\" under screen \"" &
        SplScreenName & "\" (scan reached level " & $gSplScanDeepest & " of " &
        $SplScanDepth & ", visited " & $gSplScanNodes & " node(s))"
      if gSplScanCut == 0:
        # EXHAUSTIVE. Nothing was cut off, so this node genuinely does not
        # contain the heading -- it is the wrong node of that name. Say so,
        # and put it on the ledger so the next hunt looks PAST it instead of
        # re-finding, re-scanning and re-rejecting it forever.
        splReject(screen)
        gSplScanCut = 0
        splDiag("REAL ABSENCE, not a budget: the scan of " & where &
          " ran to EXHAUSTION -- it ran out of neither nodes nor time -- and " &
          "that heading is NOT under this node. This node of that name is now " &
          "on the rejected ledger (" & $gSplRejected.len & " entry/entries) " &
          "and the next hunt will look PAST it for another node named \"" &
          SplScreenName & "\". Raising a budget CANNOT fix this.")
      else:
        let cut = (case gSplScanCut
          of 1: "the NODE BUDGET (" & $SplNodeBudget & ")"
          of 2: "the WALL-CLOCK SLICE (" & $int(SplWalkMs) & " ms)"
          of 4: "the DEPTH CAP (" & $SplScanDepth & ")"
          else: "an unreadable screen root (it could not start)")
        splDiag("BUDGET, not absence: the scan for " & where &
          " was CUT OFF by " & cut & ", so it never proved anything about " &
          "whether the heading is there. This is a TUNING bug in this file, " &
          "not a missing control -- raise that bound. The screen is NOT " &
          "rejected on this evidence.")
      # THE MISSING NEGATIVE. `frames-to-apply=1 PASS` measures how fast we
      # apply ONCE RESOLVED; it passed for a whole session in which the heading
      # was never resolved at all and the player saw vanilla throughout. So the
      # thing that must be asserted is RESOLUTION, and it must be said ONCE,
      # loudly, at error level -- not as a warn repeated forever.
      if gSplUnresolvedRounds >= SplUnresolvedFail and not gSplGaveUpLogged:
        gSplGaveUpLogged = true
        fail "singleplayer rebrand: FAIL -- the heading TMP has NEVER been " &
          "resolved this session, after " & $gSplUnresolvedRounds &
          " consecutive discovery rounds. The screen \"" & SplScreenName &
          "\" IS being found; the heading \"" & SplHeadNode & "\" under it is " &
          "not. The player is seeing the VANILLA page. Last round ended " &
          (if gSplScanCut == 0: "EXHAUSTIVELY (real absence -- wrong node of " &
             "that name; see the rejected ledger)"
           else: "CUT OFF by a bound (a TUNING bug -- raise it)") &
          ", having reached level " & $gSplScanDeepest & " over " &
          $gSplScanNodes & " node(s). This is a FAIL, not a warning, and it " &
          "is stated once rather than repeated."
      cSpAdd(SpDiag, tG2)
      return                              # screen present but heading not read yet
    if gSplForceOffline and gSplToggle == nil:
      let tG3 = cSpNow()
      splDiag("screen \"" & SplScreenName & "\" WAS found, but its practice " &
        "UpdatableToggle (under \"" & SplBlockerName & "\") was not read within " &
        "depth " & $SplScanDepth & "/" & $int(SplWalkMs) & " ms -- the screen " &
        "may still be building; retrying.")
      cSpAdd(SpDiag, tG3)
      return                              # screen present but toggle not read yet
    gSplResolved = true
    gSplRescanMisses = 0
    # RESOLUTION HAPPENED. Reset the give-up counter and publish the MEASUREMENT
    # every bound in this file should have been sized against in the first
    # place. Logged once per session, at ok level, with both numbers.
    gSplHeadEverResolved = true
    gSplUnresolvedRounds = 0
    gSplGaveUpLogged = false
    if not gSplMeasureLogged:
      gSplMeasureLogged = true
      okLog "singleplayer rebrand: MEASURED distance from the screen root to " &
        "the heading -- \"" & SplHeadNode & "\" sits at BFS level " &
        $gSplHeadDepth & " below \"" & SplScreenName & "\", reached after " &
        $gSplHeadNodes & " node(s) of a " & $SplNodeBudget & "-node budget " &
        "(scan depth cap " & $SplScanDepth & ", slice " & $int(SplWalkMs) &
        " ms). THESE are the numbers any future bound must be sized from, " &
        "with headroom -- the depth-4/2500-node tier-1 bound that broke this " &
        "feature was sized from a code comment instead."
    let tG4 = cSpNow()
    okLog "singleplayer rebrand: resolved on \"" & SplScreenName &
          "\" -- heading TMP " & (if gSplHeadTmp != nil: "found" else: "MISSING") &
          ", description TMP " & (if gSplDescTmp != nil: "found" else: "not found") &
          ", checkbox GameObject " &
          (if gSplCheckGo != nil: "found" else: "NOT found") &
          ", UpdatableToggle component " &
          (if gSplToggle != nil: "found" else: "NOT found") &
          ", co-op/progress warning " &
          (if gSplWarnGo != nil: "found (\"" & gSplWarnName & "\")"
           else: "not found") &
          ". Walking from the live scene root, by displayed text -- no " &
          "hardcoded child path."
    cSpAdd(SpDiag, tG4)

  # splMaintain brackets its OWN phases (MAINT.head / MAINT.tog / MAINT.warn and
  # the once-only summary as DIAG), so no bracket here -- one here would
  # double-count and break the partition.
  splMaintain()

proc splNoteFault() =
  ## Rule 6, in one place so both entry points (the show event and the rider)
  ## account a fault identically.
  inc gSplFaults
  warn "singleplayer rebrand: the guarded body faulted (" & $gSplFaults &
       " of " & $SplMaxFaults & ")"
  if gSplFaults >= SplMaxFaults:
    gSplOff = true
    gSplWindow = 0
    warn "singleplayer rebrand: too many faults; switching itself off for " &
         "this session and leaving the stock screen alone. This is a " &
         "REFUSAL, not a success."

proc splRunGuarded(): bool =
  ## ONE `aowl_p_p_seh`, entered from exactly two places and never nested. The
  ## profiler bracket is taken strictly OUTSIDE it, because that guard is not
  ## re-entrant and this opens none of its own.
  gSplWorkFrames = gSplWorkFrames + 1
  cSpCallBegin()
  let tCall = cSpNow()
  let rc = cSplTickGuarded(nil)
  cSpCallEnd(tCall)
  if rc == nil:
    splNoteFault()
    return false
  result = true

var gSplCostLogs = 0
var gSplIdleProofAt = 0'u64      ## ms at which the idle proof is due; 0 = none
const SplIdleProofMs = 60000'u64 ## how long after a window closes we assert idleness

proc splCloseWindow(why: string) =
  ## Close the show window and publish the PER-FRAME COST READBACK. Reports the
  ## work this window cost and arms the idle proof; both numbers are of the
  ## FINISHED state (nodes actually visited), not of our intent.
  gSplWindow = 0
  gSplSettled = 0
  let spent = gSplWindowFramesUsed
  let nodes = gSplNodes - gSplNodesAtIdle
  if gSplCostLogs < 4:
    gSplCostLogs = gSplCostLogs + 1
    okLog "singleplayer rebrand: SHOW WINDOW CLOSED after open #" & $gSplOpens &
          " -- " & why & ". PER-FRAME COST: this window spent " & $spent &
          " frame(s) of work and visited " & $nodes & " live-tree node(s) (" &
          (if spent > 0: $(nodes div spent) else: "0") & " nodes/frame while " &
          "OPEN). The feature is now IDLE: the rider returns on two integer " &
          "compares and visits ZERO nodes until the screen is shown again. " &
          "The same measurement BEFORE the show hook was ~64 nodes per 18 ms " &
          "slice at ~10 Hz, forever, resolving nothing."
  gSplNodesAtIdle = gSplNodes
  gSplWindowFramesUsed = 0
  gSplIdleProofAt = cNowMs() + SplIdleProofMs

proc splRebrandOnScreenShown(self: Il2CppPtr): bool =
  ## THE SHOW EVENT. Called by `uihooks.nim` from the POSTFIX of
  ## `MatchmakerOfflineRaidScreen::Show` @0x1788590, on Unity's main thread,
  ## with the live screen in `self`. Returns false ONLY if the guarded body
  ## faulted, so uihooks can stop dispatching into a broken subscriber.
  ##
  ## This does the FIRST pass immediately, here, rather than waiting for the
  ## next rider tick: the point of the event is that the screen is available
  ## NOW, and a frame of latency is a frame of vanilla text.
  result = true
  if (not gSplOn and not gSplForceOffline) or gSplOff: return
  if gSplT0 == 0'u64: gSplT0 = cNowMs()
  gSplShowSelf = self
  gSplShowPending = true
  gSplWindow = SplShowWindowFrames
  gSplWindowFramesUsed = 0
  gSplNodesAtIdle = gSplNodes
  gSplSettled = 0
  gSplFrames = 0
  gSplIdleProofAt = 0'u64
  gSplOpens = gSplOpens + 1
  if gSplOpens <= 4:
    okLog "singleplayer rebrand: SHOW EVENT #" & $gSplOpens & " -- the game " &
          "handed us the live \"" & SplScreenName & "\" (0x" &
          hexOf(cast[uint64](self)) & ") from the postfix of " &
          "MatchmakerOfflineRaidScreen::Show @0x1788590. Applying now, from " &
          "THIS object; no scene-root walk, no name hunt."
  result = splRunGuarded()

proc splRebrandDrainTick() =
  ## Rides the `EFT.TarkovApplication::Update` drain (slot alias, no second
  ## detour).
  ##
  ## EVENT-DRIVEN (the normal case, `gSplEventDriven`): when no show window is
  ## open this is TWO integer compares and returns. It makes no call into the
  ## game, walks nothing, and allocates nothing. All the work happens inside a
  ## bounded window opened by `splRebrandOnScreenShown`.
  ##
  ## LEGACY (only when the show hook did not bind, and said so at boot): the
  ## original adaptive cadence, kept so a build whose prologue does not match
  ## still gets the feature rather than silently losing it.
  if (not gSplOn and not gSplForceOffline) or gSplOff: return
  if gSplT0 == 0'u64: gSplT0 = cNowMs()
  if cNowMs() - gSplT0 < SplWarmupMs: return   # the menu cannot be up yet
  gSplTickFrames = gSplTickFrames + 1
  # Count REAL frames for the flash measurement, before any throttle, so the
  # number reported is frames the player actually saw -- not ticks we took.
  if gSplStockSeen and gSplFlashFrames < 100000: inc gSplFlashFrames

  if gSplEventDriven:
    if gSplWindow <= 0:
      # ---- THE IDLE PATH. This is the whole steady-state cost of the feature.
      # The idle proof below is a check that CAN fail: it reports the nodes this
      # feature visited while it claimed to be idle, and a non-zero there is a
      # bug, not a formality. It disarms itself after firing once.
      if gSplIdleProofAt != 0'u64 and cNowMs() >= gSplIdleProofAt:
        gSplIdleProofAt = 0'u64
        let leaked = gSplNodes - gSplNodesAtIdle
        if leaked == 0:
          okLog "singleplayer rebrand: IDLE PROOF PASS -- " &
                $int(SplIdleProofMs div 1000'u64) & " s after the window " &
                "closed this feature has visited " & $leaked & " live-tree " &
                "nodes and entered its guarded body " & $gSplWorkFrames &
                " time(s) in total across " & $gSplTickFrames & " rider tick(s). Steady-state cost is 0 nodes/frame."
        else:
          warn "singleplayer rebrand: IDLE PROOF FAIL -- " & $leaked &
               " live-tree node(s) were visited while this feature was " &
               "supposed to be idle. Something is still walking off a cadence."
      return
    gSplWindow = gSplWindow - 1
    gSplWindowFramesUsed = gSplWindowFramesUsed + 1
    # SETTLE, on the FINISHED STATE and not on our own writes: count only frames
    # on which the live tree already read ours and we therefore did nothing. A
    # run of those is the only honest evidence LocalizedText has stopped
    # clobbering the caption.
    if gSplResolved and gSplConfirmed:
      gSplSettled = gSplSettled + 1
      if gSplSettled >= SplSettleFrames:
        splCloseWindow("the finished-state readback held for " &
                       $SplSettleFrames & " consecutive frames")
        return
    else:
      gSplSettled = 0
    inc gSplFrames
    # Re-assert EVERY frame once resolved (from cached pointers: no walking),
    # and re-scan the ONE screen we were handed on a throttle while it is not.
    let everyE = (if gSplResolved: SplSteadyFrames else: SplRescanEveryFrames)
    if gSplFrames < everyE: return
    gSplFrames = 0
    discard splRunGuarded()
    if gSplWindow <= 0:
      splCloseWindow("the " & $SplShowWindowFrames & "-frame window cap was " &
                     "reached without the readback settling -- if this line " &
                     "keeps appearing the relabel is NOT holding, which is a " &
                     "FAIL, not a timeout")
    return

  inc gSplFrames
  # THE ADAPTIVE THROTTLE, and it lives here because this is the side that
  # decides whether to enter the guard at all (the shape `hide seasons` uses,
  # modstab.nim ~3439):
  #   * targets cached -> EVERY frame. The body then only re-asserts the
  #     finished state from cached, liveness-checked pointers: no scene
  #     enumeration, no managed allocation. This is what closes the "vanilla
  #     screen for a few seconds" window on (re)open and on rebuild.
  #   * screen cached  -> every SplRescanFrames: a depth-limited scan inside the
  #     screen, bounded by SplWalkMs.
  #   * nothing cached -> SplHuntFrames: `iSceneRoots` allocates and must not run
  #     per frame.
  #   * UI ROOT cached, screen not -> SplCheapHuntFrames: a depth-8 name descent
  #     from the cached "Menu UI" transform. NO scene enumeration and NO managed
  #     allocation, so it can run every frame -- and THAT is the fix for the
  #     user-visible half: the frame the offline-raid screen appears is the frame
  #     we find it, instead of up to SplHuntFrames (~1 s) later.
  let every = (if gSplResolved: SplSteadyFrames
               elif gSplScreen != nil: SplRescanFrames
               elif gSplUiRoot != nil: SplCheapHuntFrames
               else: SplHuntFrames)
  if gSplFrames < every: return
  gSplFrames = 0
  # THE OUTER BRACKET is taken inside `splRunGuarded`, strictly OUTSIDE
  # `cSplTickGuarded` -- `aowl_p_p_seh` is not re-entrant and nothing here opens
  # a guard of its own.
  discard splRunGuarded()

# ---------------------------------------------------------------------------
# SUBSCRIBING TO THE SHOW EVENT
# ---------------------------------------------------------------------------
proc splWantShowHook() =
  ## Declare the subscription. MUST run before the single `uihArm` pass -- a
  ## site nobody wanted is never patched, which is the point.
  if not gSplOn and not gSplForceOffline: return
  uihWant(UihSiteOfflineRaid)

proc splShowHookVerdict() =
  ## Read back whether the subscription actually BOUND, after `uihArm`. Says
  ## which of the two modes this session is in, loudly, because the difference
  ## is the entire performance question the user raised.
  if not gSplOn and not gSplForceOffline: return
  # Bound to a local first: nimony refuses to borrow an iteration path from a
  # call's temporary ("path is not borrowable"), and a `for ln in f()` here is
  # exactly that.
  let uihLines = uihStatusLines()
  var li = 0
  while li < uihLines.len:
    info "uihooks:" & uihLines[li]
    li = li + 1
  gSplEventDriven = uihBound(UihSiteOfflineRaid)
  if gSplEventDriven:
    okLog "singleplayer rebrand: EVENT-DRIVEN. The screen arrives from the " &
          "POSTFIX of MatchmakerOfflineRaidScreen::Show @0x1788590 " &
          "(sharedness UNIQUE, 16-byte prologue matched). There is NO " &
          "per-frame search: between opens the rider returns on two integer " &
          "compares and visits zero live-tree nodes. Each open opens a bounded " &
          "window of at most " & $SplShowWindowFrames & " frames which closes " &
          "early once the finished-state readback holds for " &
          $SplSettleFrames & " consecutive frames."
  else:
    warn "singleplayer rebrand: the show hook did NOT bind, so this session " &
         "falls back to the LEGACY CADENCE HUNT -- a throttled walk of the " &
         "live scene roots, which is exactly the per-frame cost the show hook " &
         "exists to remove. This is announced, not silent. The reason the " &
         "hook refused is in the `uihooks:` line above; the usual causes are " &
         "a different game build or another detour having patched " &
         "0x1788590 first (a hook-ORDER problem)."

# ---------------------------------------------------------------------------
# THE PHASE REPORT. Emitted by `drainprof.nim` on the same throttle as the
# drain-profiler line, so the row and its decomposition are always read from
# the same run.
# ---------------------------------------------------------------------------
proc splProfUs(ns: int64): string =
  ## Microseconds, to one decimal, with the unit ATTACHED. `n/a` for a sentinel.
  ## A sentinel is never printed as a value -- a `0.0us` reads as "free".
  if ns < 0: return "n/a"
  let tenths = (ns * 10'i64) div 1000'i64
  $(tenths div 10) & "." & $(tenths mod 10) & "us"

proc splProfPct(part, whole: int64): string =
  if whole <= 0: return "n/a"
  let t = (part * 1000'i64) div whole
  $(t div 10) & "." & $(t mod 10) & "%"

proc splProfLines(): seq[string] =
  ## The disjoint, exhaustive decomposition of the `splRebrandDrain` row.
  ## Prints `accounted=X of Y us (Z%)` and then, ALWAYS, the UNEXPLAINED
  ## remainder as its own line -- the remainder is never folded into a phase.
  result = @[]
  let totalNs = cSpTotalNs()
  let totalCalls = cSpTotalCalls()
  if totalCalls <= 0:
    result.add "  splRebrandDrain phases: the rider NEVER RAN under the meter " &
      "(0 bracketed calls). This is \"not measured\", NOT \"free\"."
    return
  var accounted = 0'i64
  var anyPhaseCalls = 0'i64
  let slots = cSpSlots()
  var i = 0'i32
  while i < slots and int(i) < SpNames.len:
    if i != cSpCtrlSlot():
      accounted = accounted + cSpNs(i)
      anyPhaseCalls = anyPhaseCalls + max(cSpCalls(i), 0'i64)
    inc i
  result.add "  splRebrandDrain PHASE METER -- " & $totalCalls &
    " bracketed calls, TOTAL " & splProfUs(totalNs) & ", mean " &
    splProfUs(totalNs div totalCalls) & "/call, MAX " &
    splProfUs(cSpTotalMax()) & ". All durations MICROSECONDS."
  # ---- THE DEFECT GATE. It runs BEFORE the table, and when it fires the table
  # below is a table of zeros, which is the single most misleading thing this
  # file can print. `accounted == 0` while the whole recorded real time is not a
  # measurement of a free feature -- it is a BROKEN INSTRUMENT, and it must
  # scream rather than render. The two causes are distinguished, because they
  # have different fixes: no phase bracket ran at all (the phases are on a code
  # path the feature does not take) versus brackets ran but accumulated nothing
  # (the accumulator being read is not the one being written, or every sample
  # was rejected -- see `dropped samples` on the ladder line).
  if accounted <= 0 and totalNs > 0:
    result.add "    *** PHASE METER IS DEFECTIVE -- DO NOT READ THE TABLE " &
      "BELOW. accounted=0us while the outer bracket recorded " &
      splProfUs(totalNs) & " over " & $totalCalls & " call(s). That is 100% " &
      "UNEXPLAINED. " &
      (if anyPhaseCalls <= 0:
         "NO phase bracket was entered even once, so the phases sit on a code " &
         "path this feature never takes -- the decomposition does not describe " &
         "the running code."
       else:
         $anyPhaseCalls & " phase bracket(s) WERE entered and still summed to " &
         "zero, so the accumulator being reported is not the one being " &
         "written, or every sample was rejected (check `dropped samples`).") &
      " This attribution is VOID. Every phase figure below is INCONCLUSIVE, " &
      "and INCONCLUSIVE is not a PASS."
  i = 0'i32
  while i < slots and int(i) < SpNames.len:
    let c = cSpCalls(i)
    let ns = cSpNs(i)
    let nm = (if int(i) < SpNames.len: SpNames[int(i)] else: "slot " & $int(i))
    if c <= 0:
      # RULE 4: "never ran" is not "cheap". It never prints as 0.0us.
      result.add "    " & nm & ": NEVER RAN (0 calls) -- unmeasured, not free."
    else:
      # A bucket whose samples were mostly BELOW the QPC tick is "too small for
      # this clock", which is a different claim from "cheap" -- say which.
      let sub = cSpSubtick(i)
      let subNote = (if sub > 0: " [" & $sub & " of " & $c &
        " samples measured BELOW the clock tick -- that part is 'too small to " &
        "measure', not 'free']" else: "")
      result.add "    " & nm & ": " & splProfUs(ns) & " over " & $c &
        " calls (mean " & splProfUs(ns div c) & ", max " &
        splProfUs(cSpMax(i)) & ", " & splProfPct(ns, totalNs) & " of total)" &
        subNote
    inc i
  result.add "    accounted=" & splProfUs(accounted) & " of " &
    splProfUs(totalNs) & " (" & splProfPct(accounted, totalNs) &
    "); CONTROL is excluded from `accounted` on purpose -- it is the honesty " &
    "probe, not work the feature does."
  let unex = totalNs - accounted
  result.add "    UNEXPLAINED: " & splProfUs(unex) & " (" &
    splProfPct(unex, totalNs) & ") is OUTSIDE every bracket -- guard entry/exit " &
    "and any statement no phase covers. If this is large the decomposition is " &
    "WRONG and the phases above must not be trusted."
  # THE TAIL, which is a different question from the mean.
  let slow = cSpSlowCalls()
  if slow <= 0:
    result.add "    TAIL: NO call exceeded " & splProfUs(cSpSlowThresholdNs()) &
      " in this run."
  else:
    var by = ""
    i = 0'i32
    while i < slots and int(i) < SpNames.len:
      if cSpSlowBy(i) > 0:
        let nm = (if int(i) < SpNames.len: SpNames[int(i)] else: $int(i))
        by = by & " [" & nm & " x" & $cSpSlowBy(i) & "]"
      inc i
    if cSpSlowUnexp() > 0:
      by = by & " [NO PHASE DOMINATED x" & $cSpSlowUnexp() & "]"
    result.add "    TAIL: " & $slow & " of " & $totalCalls &
      " calls exceeded " & splProfUs(cSpSlowThresholdNs()) & " (" &
      splProfPct(slow, totalCalls) & " of calls, " &
      splProfPct(cSpSlowNs(), totalNs) & " of total time). Dominated by:" & by &
      ". \"Dominated\" = one phase held over half that call."
  result.add "    discovery ladder: UI-root cache hits=" & $gSplUiRootHits &
    ", anchor-scene-only enumerations=" & $gSplNarrowWalks &
    ", FULL all-scene enumerations=" & $gSplFullWalks &
    " (the last is the 194ms step; it is throttled to one per " &
    $int(SplFullWalkEveryMs div 1000'u64) & "s and kept only so a screen that " &
    "MOVED scenes stays findable). cached UI root=" &
    (if gSplUiRoot != nil: "\"" & gSplUiRootName & "\"" else: "NONE") &
    ", dropped samples=" & $cSpDropped() & "."
  # THE STEADY-STATE CLAIM, stated so it can be FALSIFIED. The re-apply is not
  # skipped -- only the string DECODE is, and only while the m_text String
  # object is byte-identically the same reference we already verified as ours.
  # A miss is a full decode AND, if it does not read as ours, a re-apply. So:
  # `latch misses` is an upper bound on the frames that could have re-applied,
  # and if the rebrand ever flickers back to BSG's caption this number must be
  # non-zero on that frame -- a latch that hid a clobber would show hits with a
  # visibly wrong screen, which is the observation that would refute this.
  # RESOLUTION FIRST -- it is the precondition for every other number here.
  # A steady-state cost of "nearly nothing" is trivially achievable by never
  # resolving, so the cost rows below are meaningless until this line says the
  # heading was actually resolved.
  result.add "    RESOLUTION: heading TMP " &
    (if gSplHeadEverResolved:
       "RESOLVED (MEASURED at BFS level " & $gSplHeadDepth & ", " &
       $gSplHeadNodes & " nodes below the screen root)"
     else:
       "*** NEVER RESOLVED this session after " & $gSplUnresolvedRounds &
       " round(s) -- the player is seeing the VANILLA page and every cost " &
       "figure below is the cost of FAILING, not of working ***") &
    "; rejected same-named screen nodes=" & $gSplRejected.len & "."
  result.add "    m_text identity latch: " & $gSplLatchHits &
    " hit(s) (one guarded pointer read, no decode, no allocation) vs " &
    $gSplLatchMiss & " miss(es) (full decode; a miss that does not read as " &
    "ours RE-APPLIES on that frame). The latch accelerates the CHECK only -- " &
    "it never suppresses a re-apply. If the heading is ever seen reading " &
    "\"PRACTICE GAME MODE\" while this shows hits and no misses, the latch is " &
    "WRONG and must be removed."
