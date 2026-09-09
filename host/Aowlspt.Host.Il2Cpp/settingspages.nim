# settingspages.nim -- PHASE 3: a per-mod settings PAGE inside Tarkov's own
# settings screen.
#
# `include`d into `aowlhost.nim` after `settingswrite.nim`, whose primitives it
# is built entirely out of: the klass census that types a control without
# reflection, the label chain that can be written, and the guarded value
# read/write. It adds three things those do not have:
#
#   1. a SCHEMA -- a page is a name plus a list of rows, and a row is a config
#      key, a label, a kind and a default. This is the same shape mods already
#      declare through `aowlspt/settings` (`aowl/src/aowlspt/settings.nim`) and
#      already serve at `/aowlspt/settings/<guid>`; see the seam note below.
#   2. a RENDERER -- rows become real Unity controls by CLONING a stock control
#      of the right widget type and retargeting the clone. Cloning is the
#      reflection-free way to make a control on this build, and it is already
#      proven here (`invoke2.nim` STEP 5 clones a live settings label).
#   3. a BINDING -- the clone shows the config's value, and the value the player
#      leaves it at is read back and persisted.
#
# WHY CLONING RATHER THAN CREATING
# --------------------------------
# The game builds a row with `SettingsTab::CreateControl<T>` @0x2B86E20. That is
# ONE shared-generic body serving every T, with the T carried entirely in the
# hidden MethodInfo* -- and a shared generic is the single documented case where
# passing NULL for that MethodInfo is NOT safe (see `abi/aowlspt_invoke2.h`).
# Obtaining a real generic MethodInfo needs the metadata reflection that is dead
# on this build. So the row cannot be constructed; it can only be copied.
#
# THE SEAM (deliberate, and named so the next step is wiring rather than design)
# -----------------------------------------------------------------------------
# `swPageRegister` takes a fully-formed `SwPage`. This file ships ONE built-in
# page -- the aowlspt host's own flags, which the host can read without asking
# anyone. Every OTHER mod's page already exists as JSON at
# `/aowlspt/settings/<guid>`, in exactly the {key,label,type,value,min,max,
# options,implemented} shape `SwRow` mirrors field for field. Turning those into
# pages is a fetch and a parse into `swPageRegister`, not a redesign: the
# renderer below neither knows nor cares where a page came from.
#
# SAFETY
# ------
# Default OFF (`settingsPages`). Runs inside the settings postfix's existing
# `aowl_p_p_seh` guard and arms no second one (that guard is not re-entrant).
# Every pointer hop is `cIsReadable`-guarded, every loop is capped, every direct
# call is to a byte-verified prologue, and the whole thing shares
# `settingswrite.nim`'s fault budget -- two faults and it stops for the session.
# Nothing here ever writes to a control the GAME created: it writes only to
# clones it made itself, and it refuses to render at all if it cannot identify
# the widget type it needs.

# ---- the Phase 3 setter table (abi/aowlspt_settingswrite.h) ----
proc cSwFn(i: int32): Il2CppPtr {.importc: "aowl_sw_fn", nodecl.}
proc cSwFnName(i: int32): Il2CppPtr {.importc: "aowl_sw_name", nodecl.}
proc cSwFnRva(i: int32): uint32 {.importc: "aowl_sw_rva", nodecl.}
proc cSwFnCount(): int32 {.importc: "aowl_sw_target_count", nodecl.}
proc cSwFnOk(): int32 {.importc: "aowl_sw_ok_count", nodecl.}
proc cSwFnBad(): int32 {.importc: "aowl_sw_bad_count", nodecl.}
proc cSwCallVPF(fn, self: Il2CppPtr; v: float64) {.
  importc: "aowl_sw_call_v_pf", nodecl.}
proc cSwCallVPB(fn, self: Il2CppPtr; b: int32) {.
  importc: "aowl_sw_call_v_pb", nodecl.}
proc cSwCallVP(fn, self: Il2CppPtr) {.importc: "aowl_sw_call_v_p", nodecl.}

const
  SwToggleNoNotify  = 0'i32
  SwToggleSetIsOn   = 1'i32
  SwSliderNoNotify  = 2'i32
  SwSliderSetMin    = 3'i32
  SwSliderSetMax    = 4'i32
  SwSliderRepaint   = 5'i32

## Forward-declared: implemented in `modsettingsrender.nim`, `include`d after
## this file. Queues a POST to the mod that owns `guid` on the overlay's own
## worker thread -- never blocks this (the Unity main) thread.
proc modSetQueueWrite(guid, key, val: string)

## Also forward-declared, same file, same reason. Drains the mod pages the host
## tick thread has parsed and STAGED into `gSwPages`, on THIS (the Unity main)
## thread. `gSwPages` is a Nim seq read by `swPagesOnTabBuilt` and
## `modsBuildPages` on this thread; the fetch thread appending to it directly
## reallocated the buffer under those readers, which is a use-after-free by
## construction. It stages now, and this is the only place the registry grows
## from a fetch.
proc modSetDrainStaged()

proc swFn(i: int32): Il2CppPtr =
  ## A byte-verified setter, or nil. Logged on refusal so a target that did not
  ## verify on this build is never mistaken for a row that rendered and did
  ## nothing.
  result = cSwFn(i)
  if result == nil:
    warn "settings pages: setter " & readCString(cSwFnName(i)) & " @ 0x" &
         hexOf(uint64(cSwFnRva(i))) & " did not verify on this build; the row " &
         "that needs it is skipped rather than rendered wrong"

# ---------------------------------------------------------------------------
# The schema
#
# Field-for-field the subset of `aowlspt/settings.Setting` that a NATIVE control
# can express. `stEnum`/`stString`/`stKeybind` have no clone-able widget yet and
# are carried as `swkStub` rows -- drawn, labelled, and honestly marked as not
# wired, which is the same discipline `implemented = false` already has in the
# schema module.
# ---------------------------------------------------------------------------
type
  SwKind* = enum
    swkStub                     ## drawn and labelled, bound to nothing yet
    swkToggle                   ## a bool -> SettingToggle clone
    swkSlider                   ## a float -> SettingFloatSlider clone
    swkColor                    ## an RGB colour -> a NUIKIT-BUILT widget
    swkChoice                   ## an enum -> a CLONED SettingDropDown, filled
    ## by the game's own `BaseDropDownBox::Show` through the receiver's own
    ## vtable slot 24 -- the identical mechanism `dlssrows.nim` uses, reached
    ## through `nuDropDownOf`/`nuDropDownShow`/`nuDropDownReseat` rather than
    ## copied. A `swkChoice` row that cannot get a dropdown donor, or whose
    ## `Show` refuses any of its six proofs, is DEMOTED back to `swkStub` and
    ## says so -- it is never faked out of a toggle.
    ## `swkColor` is the ONE kind here that is not a clone of a game widget.
    ## There is no colour control anywhere on a stock settings tab to clone, so
    ## it is BUILT from `nuPanel`/`nuLabel` primitives (a swatch, three channel
    ## tracks with fills, and a readout) and driven by POLLED pointer input off
    ## the Update drain. See `colorwidget.nim`; `settingspages.nim` only calls
    ## the three entry points forward-declared below.

const
  # THE COLOUR FORMAT VOCABULARY, mirroring `cColorFmt*` /
  # `normalizeColorFormat` in `aowl/src/aowlspt/settings.nim`. The host cannot
  # import the mod SDK, so this is a mirror rather than a shared symbol -- but
  # it is ONE mirror, named, in one place, referenced by both the parser and the
  # writer, instead of the bare string literals that let the two UIs drift.
  # `rgb` is the DEFAULT on both sides, and it is the default that was broken.
  cSwColorFmtRgb* = "rgb"          ## "r,g,b" / "r,g,b,a", components 0..1
  cSwColorFmtHex* = "hex"          ## "rrggbb" / "rrggbbaa", NO leading '#'
  cSwColorFmtHexHash* = "hex#"     ## "#rrggbb" / "#rrggbbaa", WITH the '#'

type
  SwRow* = object
    key*: string                ## the config key, verbatim
    label*: string              ## the text drawn on the row
    kind*: SwKind
    bval*: bool                 ## current value, for swkToggle
    fval*: float64              ## current value, for swkSlider
    lo*: float64
    hi*: float64
    implemented*: bool          ## false -> suffixed with the not-wired marker
    category*: string           ## "" -> ungrouped. A mod schema's `category`
    ## field, used only to insert a header row ahead of each group (see
    ## `modSetGroupByCategory` in `modsettingsrender.nim`) -- the renderer
    ## below treats a header exactly like any other `swkStub` row, so it needs
    ## no code of its own here.
    ## Filled by the renderer: the clone this row is showing on, and the value
    ## it was last seeded with, so a change made by the player can be spotted.
    clone*: uint64
    seeded*: bool
    ## SLICING. `swRenderPage` used to draw a whole page inside one frame, so
    ## "this row has a clone" and "this row has been captioned" were the same
    ## fact and neither needed recording. With the renderer sliced they are
    ## two facts separated by frames: `modstab.nim` re-asserts every caption
    ## across all of a row's TextMeshProUGUIs (fact #88 -- the single-TMP write
    ## lands and the row still reads the donor's caption), and it must do that
    ## for rows that appeared THIS tick without re-walking the ones it already
    ## did. A latch, not a count: a count cannot say WHICH row was missed.
    relabelled*: bool
    ## Current value for `swkColor`, 0..1 per channel. Kept as four floats
    ## rather than a packed uint32 because that is the form every setter on the
    ## path (`Graphic::set_color`, `nuSetColor`) actually takes, and a
    ## conversion that exists only at the edges is one that cannot be got wrong
    ## in the middle.
    cr*: float32
    cg*: float32
    cb*: float32
    ca*: float32
    ## Index into `colorwidget.nim`'s fixed widget table, BIASED BY ONE:
    ## 0 means "this row has no colour widget", n means table slot n-1.
    ##
    ## The bias is not cosmetic. `SwRow` is default-constructed in several
    ## places (`swRow`, the header rows in `modSetGroupByCategory`, every
    ## `SwRow(kind: ...)` literal), and a plain index would default to 0 --
    ## which is a VALID slot. Every non-colour row in the host would then claim
    ## to own widget 0, and the first colour row built would be driven, read
    ## back and persisted through all of them. Biasing makes the default mean
    ## what it has to mean.
    ##
    ## NOT a pointer: the widget owns several nuikit handles whose lifetime is
    ## its own, and a raw pointer here would be exactly the stale-handle bug
    ## nuikit's generation counters exist to prevent.
    cwIdx*: int32
    ## The colour row's DECLARED text shape -- one of the three `cSwColorFmt*`
    ## constants below, mirroring `normalizeColorFormat` in
    ## `aowl/src/aowlspt/settings.nim`. Carried because it decides what is
    ## WRITTEN BACK: this used to be ignored and every colour edit was persisted
    ## as `#rrggbb`, which the owning mod's own reader rejects for both of the
    ## other two formats, so the edit reverted on the next read.
    cfmt*: string
    ## Did the stored value carry an alpha component? A colour written back with
    ## an alpha the row never had is a value the mod did not store, and for the
    ## `hex` format it also changes the LENGTH, which is what mod readers key
    ## off. Never invent one.
    cHasA*: bool
    ## The SCHEMA said `type:"color"`, whatever this row ended up being rendered
    ## as. Survives demotion to `swkStub` on purpose: it is the only thing that
    ## makes the falsifiable negative -- "no setting whose schema declares a
    ## colour format still renders as a stub or a bare text row" -- possible to
    ## state at all. Without it a demoted colour row is indistinguishable from a
    ## string row, and the check could only ever say yes.
    declaredColor*: bool
    ## THIS ROW IS THE MOD'S OWN ENABLED SWITCH, not one of its settings.
    ##
    ## It renders as an ordinary `swkToggle` (it IS one -- the same cloned
    ## `SettingToggle` every other bool row uses), and everything about drawing,
    ## seeding and reading it back is unchanged. What differs is the ONE thing
    ## that must differ: where a change goes. A settings row POSTs to
    ## `/aowlspt/settings/<guid>`; this one is not a setting of the mod at all,
    ## it is the mod manager's selection, and writing it to the settings route
    ## would create a config key called `__enabled` that nothing reads while
    ## the mod stayed exactly as enabled as it was.
    ##
    ## A separate FIELD rather than a magic key, because a key comparison in
    ## the read-back is a string test that a mod author can collide with by
    ## naming a setting `__enabled`; a field cannot be collided with.
    enableRow*: bool
    ## THE ENUM ROW'S OPTIONS, verbatim from the schema, in schema order. The
    ## value is stored as a ONE-BASED index (`fval`) because that is what the
    ## config and the F12 overlay already use for a choice (see
    ## `sbdRegisterDropdown`), while the control is zero-based; the conversion
    ## lives only at the seed and the flush.
    choices*: seq[string]
    ## The values PERSISTED for those options, parallel to `choices`. An
    ## aowlspt `enum` setting stores the OPTION STRING (`aowl/src/aowlspt/
    ## settings.nim` `enumSetting`: `default: string`, `options: seq[string]`),
    ## while `optionLabels` -- when the schema ships them -- are display names
    ## only. Writing the one-based INDEX instead, which is what the DLSS rows'
    ## `sbdRegisterDropdown` flush does (its schema really is numeric), would
    ## put a value in the mod's config that the mod's own reader rejects --
    ## the identical defect the colour rows had when every format was
    ## persisted as `#rrggbb`. So the index lives only on screen and in
    ## `fval`; what crosses the wire is `choiceVals[index-1]`.
    choiceVals*: seq[string]
    ## This row's edits are owned by `settingsbind.nim` (it was registered
    ## through `sbdRegister*`), so `swReadBackPage` must NOT also write it.
    ## Two independent writers for one gesture is how a switch gets toggled
    ## twice; the field makes that impossible rather than forbidden.
    sbdBound*: bool

  SwPage* = object
    id*: string                 ## stable key, e.g. "host"
    title*: string              ## the heading row's text
    rows*: seq[SwRow]
    stub*: bool                 ## true -> render the heading + the stub note only
    note*: string               ## why it is a stub, shown to the player
    ## Renderer state: which tab object this page was last rendered into, so
    ## re-opening the tab does not render it twice.
    renderedFor*: uint64
    ## "" -> a local page (write-back edits `aowlspt-host.json` in place, the
    ## original `host` page). Non-empty -> a MOD page fetched from
    ## `/aowlspt/settings/<modGuid>`; write-back POSTs the edit to the mod that
    ## owns it instead (see `modsettingsrender.nim`). Kept on the page rather
    ## than threaded through every call so `swReadBackPage` needs no second
    ## signature.
    modGuid*: string
    ## ---- SLICED RENDER STATE -------------------------------------------
    ## A page is no longer drawn in one frame. These five fields ARE the
    ## renderer's resumption point, and they are on the page rather than in a
    ## side table so that `gSwPages[i] = pg` (the read-modify-write the
    ## registry already needs -- see the aliasing note in `swPagesOnTabBuilt`)
    ## carries the progress along with the rows.
    ##
    ## `begun` without `complete` is the state the whole feature exists to
    ## make usable: rows are on screen, top-down, and more arrive each tick.
    begun*: bool
    complete*: bool
    nextRow*: int            ## index of the next schema row to instantiate
    drawn*: int              ## rows actually instantiated so far
    ## Where rows are parented and what they are cloned from, captured at
    ## `begin` so a slice needs no tab pointer and no second donor search.
    renderParent*: uint64    ## GameObject: the scroll Content, or the panel
    renderDonor*: uint64     ## the row prefab instance every clone comes from
    ## THE SCROLL HOST. Non-zero -> `renderParent` is a cloned SettingsList's
    ## `Content` and the page scrolls. Zero -> it does not, and `scrollWhy`
    ## says why in words. 949 rows in a fixed-height panel are not "mostly
    ## visible", they are unreachable, so a page without a scroll host is a
    ## reported shortfall and not a quiet fallback.
    scrollGo*: uint64
    scrollWhy*: string
    skipped*: int
    lastSkipWhy*: string
    ## ---- THE GRAFT, ITS OWN TICK ---------------------------------------
    ## MEASURED (host log 2026-09-04, every one of 11 index-driven pages):
    ## "RENDER SLICE OVERRAN its budget -- page 'mod:aowl.tarkov' spent 62 ms
    ## instantiating 1 row(s)". That 62-78 ms is not row cost: it is the
    ## SettingsList clone and graft that used to run inside `begin`, landing
    ## in the same wall-clock window as the first row and being reported as
    ## the row's price. So the graft is now a STEP OF ITS OWN -- it runs on
    ## its own tick, before any row, and is clocked into its own counters.
    grafted*: bool
    graftMs*: uint64
    ## When this page visit began, and whether its verdict has been said.
    ## A verdict that only fires on completion never fires for a page that
    ## stops advancing -- which is exactly what the deployed run did: 2+
    ## minutes with the tab open and not one RENDER VERDICT line.
    beganAt*: uint64
    verdictDone*: bool
    timedOut*: bool
    verdictAt*: uint64       ## when the SETTLED verdict is due; 0 = none pending
    ## A dropdown control on the tab to clone for `swkChoice` rows, captured
    ## at `begin` from the klass census. Zero -> this tab has none, and every
    ## enum row on this page is demoted to a labelled stub that says so.
    renderDonorDrop*: uint64
    ## WHERE THAT DROPDOWN DONOR CAME FROM, in words, so the BEGUN line names
    ## the source instead of only printing a pointer. MEASURED 2026-09-04:
    ## every one of the 11 index-driven pages logged `dropdownDonor=0x0`,
    ## because the Game tab's klass census learns `gSwKlassDropdown` from a
    ## stock dropdown ROW and the Game tab has none -- the tab that has one is
    ## Graphics. See `gSwDropTemplate`.
    renderDonorDropWhy*: string
    ## THE HEADING CLONE, and the reason it is kept: the liveness test that
    ## decides whether a page "lost its clones" scanned `rows[].clone` only.
    ## A page that has had its GRAFT tick but not yet a ROW tick has no row
    ## clone at all, so that test answered "lost" for a page that was healthy
    ## and mid-render -- which is exactly what the deployed run did, on every
    ## page, on every tab-built event. The heading clone and the scroll host
    ## are the two objects a begun page always owns.
    headClone*: uint64
    ## TICKS THIS PAGE VISIT HAS CONSUMED. The second, frame-based bound on
    ## the verdict: `cSwPageVerdictMs` is wall clock and cannot fire while a
    ## page is being re-begun, and a page that is never granted a tick must
    ## still eventually account for itself. Both bounds are mandatory and
    ## neither is redundant.
    ticks*: int

## The marker a not-yet-wired row carries. Deliberately verbose: a settings row
## that silently does nothing is worse than no row, and this is the project's
## existing `implemented = false` convention made visible natively.
const cSwNotDone = "  (not done yet)"

## How many rows one page may render. A cap, not an expectation -- it bounds the
## clone count so a bad schema cannot instantiate hundreds of Unity objects into
## a live screen. Raised from 24 to fit a mod schema's real rows PLUS one
## header row per category (mods/tarkov alone is 22 rows across 8 categories =
## 30) -- still a bound, not a target.
const cSwMaxRows = 1024

## HOW MANY ROWS ONE HOST TICK MAY INSTANTIATE. This is the whole point of the
## slice: `cSwMaxRows` is now 1024 to match what `modsindex.nim`'s parser
## actually produces (aowl.tarkov alone is 949 rows, maps 61, sain 55), and
## 949 `Object::Instantiate` calls plus 949 caption re-asserts in ONE frame is
## a multi-second stall on the Unity main thread -- the rule-7 violation the
## 48-row cap was hiding rather than solving.
##
## 24 is a budget, not a target: the tick ALSO stops on `cSwSliceMs`, so a
## machine where a row costs more than expected does fewer than 24 and says so.
## Neither bound is allowed to be the only one -- a row count alone cannot
## bound time, and a clock alone cannot bound how many managed objects one
## frame creates.
const cSwSliceRows = 24

## The wall-clock half of the budget, measured with `cNowMs` (the same clock
## the inspector's find slice uses). Deliberately under a 60 Hz frame: a tick
## that overruns is reported with its worst measurement, never silently
## absorbed.
const cSwSliceMs = 8'u64

## HOW LONG A PAGE MAY FILL BEFORE IT MUST ACCOUNT FOR ITSELF.
##
## MEASURED, and this constant exists because of it: in the deployed run of
## 2026-09-04 the MODS tab was open for over two minutes and NOT ONE
## `RENDER VERDICT` line was printed for any of the 11 index-driven pages.
## The verdict only ever ran on completion, so a page that stopped advancing
## produced silence -- and silence read as "fine". A verdict that can only
## fire when the thing worked is a check that cannot fail (CLAUDE.md 9b).
##
## So the verdict is now ALSO said on a deadline, once per page visit, with
## the SHORTFALL as its subject: how many rows were asked for, how many are on
## screen, and how long the page has been trying. It does not stop the render
## -- the page keeps filling and its completion verdict still lands later.
const cSwPageVerdictMs = 12000'u64
## HOW LONG A COMPLETED PAGE SETTLES BEFORE ITS VERDICT IS JUDGED. MEASURED
## 2026-09-05 15:31 (host a220e060279c): the verdict judged at completion said
## FAIL -- "row 'debugUi' should read 'F3 debug panel' and reads 'Interface
## language'" -- and 0.8 s later the caption re-assert poll (one pass every 60
## frames) PUT BACK 2 captions; the live tree read every caption correctly and
## the verdict had already been said. A verdict over the finished page must be
## read after LocalizedText's re-resolve AND the poll behind it have both had
## their turn, which is what the player sees a second later, not the frame
## the last row landed on.
const cSwVerdictSettleMs = 1500'u64

## THE SECOND BOUND ON THE VERDICT, IN TICKS RATHER THAN MILLISECONDS.
##
## `cSwPageVerdictMs` is measured from `beganAt`, which `swRenderPageBegin`
## resets -- so a page that is re-begun more often than every 12 s can never
## reach it, and that is precisely what the deployed run did: every tab-built
## event re-began every page, and NOT ONE `RENDER VERDICT` line was printed in
## a 65-minute run. A tick count cannot be reset by anything except a genuine
## new page visit, so it fires even under that pathology.
##
## 1024 ticks at 24 rows is 24k rows -- far above `cSwMaxRows`, so a page that
## is actually progressing NEVER hits it. Reaching it means the page stopped
## advancing, and that is a TIMEOUT verdict with the shortfall named, not
## silence.
const cSwMaxPageTicks = 1024

## `EFT.UI.Settings.GraphicsSettingsTab._dropDownTemplate` @ 0xB0 -- MEASURED
## (`python tools/fldoff.py field EFT.UI.Settings.GraphicsSettingsTab
## _dropDownTemplate`), and it is the SAME offset `dlssrows.nim` reads and
## clones from successfully on this build (`DlrOffDropDownTmpl`). It is read
## here rather than borrowed from that module because `dlssrows.nim` is
## `include`d after this file and only ever holds it as a local.
##
## NULL-CAPABLE like every serialized template field, so it is treated as an
## offer and never as a guarantee: unreadable, null, or a fake-null Unity
## object all leave `gSwDropTemplate` at zero and every enum row stays a
## labelled stub that says so.
const cSwGfxDropTemplate = 0xb0'i32

## Captured on a GRAPHICS tab visit -- the tab that HAS a dropdown. The Game
## tab, where the pages render, has none, which is why the klass census leaves
## `gSwKlassDropdown` at 0 there and why `swFindDonor` on the Game tab can
## only ever return nil.
var gSwDropTemplate = 0'u64
var gSwDropTemplateWhy = ""
var gSwDropTemplateSaid = false

## Sanity bounds for a row that came off the wire (`modsettingsrender.nim`
## parses `/aowlspt/settings/<guid>` -- an HTTP response from whatever the mod
## author's process sends, not something this host authored). A row that fails
## these is SKIPPED, never rendered and never faulted on; rule 8 (never blind-
## write) applies just as much to "never blind-render".
const cSwMaxLabelLen = 200
const cSwMaxKeyLen = 200

## FORWARD DECLARATIONS into `colorwidget.nim`, which is `include`d AFTER this
## file (it needs `nuikit.nim`'s constructors and `modsettingsrender.nim`'s
## `modSetQueueWrite`, both of which come later in `aowlhost.nim`'s include
## order). nimony forward-resolves procs across an include boundary but NOT
## variables, which is why these are procs and why no `colorwidget` global is
## named here.
##
## Three entry points, and nothing else crosses the boundary:
## FORWARD DECLARATION into `settingsbind.nim` (included later), for the same
## reason as the `colorwidget` three below: the ENABLED switch's read-back
## verdict lives with the other verdicts, not here. Arms V3 for one guid --
## see `sbdVerdictEnable`.
proc swEnableWatch(guid: string; want: bool)
## And its drain, forward-declared here because `modstab.nim` is included
## before `settingsbind.nim` and drives it (see the call site there for why it
## needs a second driver).
proc sbdVerdictEnable()
## THE GRAY-OUT, forward-declared into `postfxrows.nim` (included later), which
## is where the two primitives were derived and byte-verified: the walk
## `SettingControl._blocker@0x88 | _elementBlocker@0xa0 -> UiElementBlocker.
## Group@0x20`, and the mirror of `MyExtensions::SetUnlockStatus` @0x1d20100
## (set_alpha 1.0|0.3, set_interactable, set_blocksRaycasts, in that order).
##
## REUSED RATHER THAN REDERIVED, deliberately. A second implementation of a
## gray-out would be a second set of offsets to get wrong, and the PostFX one
## already has a live verdict behind it. Either can DECLINE (a prefab instance
## may legitimately have no blocker), and a decline is reported, never treated
## as done.
proc swRowGrayGroup(ctrl: Il2CppPtr): Il2CppPtr
proc swRowGraySet(cg: Il2CppPtr; free: bool): bool
## Applies that gray-out over one page, from the page's own ENABLED switch.
## Declared here because `swRenderPage` calls it and is defined first.
proc swApplyEnableGray(page: var SwPage; why: string)
## FORWARD DECLARATION into `postfxrows.nim` (included later), for THE SCROLL
## HOST -- the one that already works.
##
## `pfxScrollify`'s v3 graft is the only thing in this codebase that has ever
## produced a scrolling settings region, and it took three attempts and a
## measured geometry verdict to get there. Its generic core is now
## `pfxScrollHostMake` / `pfxScrollHostFinish`, and `swScrollHostFor` is the
## thin entry point BOTH the PostFX page and every mods page reach it through.
## A second copy of that geometry would be a second set of rules to get wrong,
## and the two would drift the first time either was fixed.
##
## Returns false and fills `note` when no scroll host could be built. That is
## reported on the page, never swallowed: without it only the first screenful
## of a 949-row page is reachable at all.
proc swScrollHostFor(anchorT, hostGo: Il2CppPtr; contentGoOut: var Il2CppPtr;
                     note: var string): bool

proc cwBuildForRow(rowClone, parentGo: Il2CppPtr; key, modGuid: string;
                   r, g, b, a: float32): int32
proc cwRowColor(slot: int32; r, g, b, a: var float32): bool
proc cwDestroySlot(slot: int32)

proc swRowIsSane(row: SwRow; why: var string): bool =
  ## True if `row` is safe to hand to `swCloneRow`/`swSeedToggle`. Every check
  ## here is something a REMOTE schema could get wrong, honestly or not:
  ## `key`/`label` length, and `kind` being one of the three this renderer
  ## actually knows how to draw. A header row (kind=swkStub, key="") is
  ## explicitly VALID -- empty key is the documented shape for it -- so this
  ## does not reject on an empty key alone.
  why = ""
  if ord(row.kind) < ord(low(SwKind)) or ord(row.kind) > ord(high(SwKind)):
    why = "kind " & $ord(row.kind) & " is out of range"
    return false
  if row.label.len > cSwMaxLabelLen:
    why = "label is " & $row.label.len & " byte(s), over the " &
          $cSwMaxLabelLen & "-byte cap"
    return false
  if row.key.len > cSwMaxKeyLen:
    why = "key is " & $row.key.len & " byte(s), over the " & $cSwMaxKeyLen &
          "-byte cap"
    return false
  result = true

var gSwPages: seq[SwPage] = @[]
## `settingsPages` -- Phase 3. Default OFF.
var gSwPagesOn = false
## How many times the entry point has been reached this session. Logged for the
## first few so the log SHOWS the path being taken rather than leaving its
## silence to be interpreted.
var gSwPagesFires = 0

proc swPageRegister(p: SwPage) =
  ## Add a page, replacing any page already registered under the same id. The
  ## replace matters for the seam: a page fetched from a mod's schema route is
  ## re-registered whenever the schema is re-fetched, and must not accumulate.
  var i = 0
  while i < gSwPages.len:
    if gSwPages[i].id == p.id:
      gSwPages[i] = p
      return
    i = i + 1
  gSwPages.add p

# ---------------------------------------------------------------------------
# Persistence -- one key of `aowlspt-host.json`, edited in place
#
# The host reads its flags with `readBoolKey`, a deliberately shallow scan that
# needs no JSON parser. The write is its exact mirror: find the key, replace the
# token after the colon, and put the file back. Nothing else in the file moves,
# so a hand-edited config keeps its comments-by-convention, its key order and
# its formatting.
#
# A key that is not in the file yet is INSERTED after the opening brace rather
# than appended, because appending would have to find the last value and worry
# about a trailing comma, and inserting only has to worry about whether the
# object is empty.
# ---------------------------------------------------------------------------
proc swBoolText(v: bool): string =
  if v: result = "true" else: result = "false"

proc swSetHostFlag(key: string; value: bool): bool =
  ## Persist one boolean into `aowlspt-host.json`. Returns false and changes
  ## nothing if the file cannot be read or written -- a setting that fails to
  ## persist is a log line, never a crash and never a truncated config.
  result = false
  let path = joinPath(gDir, "aowlspt-host.json")
  var text = ""
  if not readTextFile(path, text):
    warn "settings pages: cannot read " & path & "; '" & key &
         "' was not persisted"
    return
  let needle = "\"" & key & "\""
  let at = find(text, needle)
  var edited = ""
  if at < 0:
    # Not present: insert straight after the opening brace.
    let brace = find(text, "{")
    if brace < 0:
      warn "settings pages: " & path & " has no JSON object in it; '" & key &
           "' was not persisted"
      return
    # An empty object needs no trailing comma; anything else does.
    var rest = ""
    var j = brace + 1
    while j < text.len:
      rest.add text[j]
      j = j + 1
    var hasMore = false
    for ch in rest:
      if ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n' and ch != '}':
        hasMore = true
        break
    var k = 0
    while k <= brace:
      edited.add text[k]
      k = k + 1
    edited.add "\n  \"" & key & "\": " & swBoolText(value)
    if hasMore:
      edited.add ","
    edited.add rest
  else:
    # Present: step past the key, the colon and any spaces, then replace the
    # token that follows with the new literal.
    var i = at + needle.len
    while i < text.len and (text[i] == ' ' or text[i] == ':' or
                            text[i] == '\t'):
      i = i + 1
    var j = i
    while j < text.len and text[j] != ',' and text[j] != '}' and
          text[j] != '\r' and text[j] != '\n':
      j = j + 1
    var k = 0
    while k < i:
      edited.add text[k]
      k = k + 1
    edited.add swBoolText(value)
    var m = j
    while m < text.len:
      edited.add text[m]
      m = m + 1
  if not writeTextFile(path, edited).ok:
    warn "settings pages: could not write " & path & "; '" & key &
         "' was not persisted (the file is unchanged)"
    return
  okLog "settings pages: persisted \"" & key & "\": " & swBoolText(value) &
        " into aowlspt-host.json"
  result = true

# ---------------------------------------------------------------------------
# The built-in page: the aowlspt host's own flags
#
# Every one of these is a real key `readBoolKey` already consumes at boot, so
# the page is honest by construction -- it shows the host's actual switches
# rather than a curated subset. They are marked `implemented = false` where the
# flag exists but changing it needs a restart to take effect, which is most of
# them: a detour is installed once, at boot, and cannot be un-installed by
# unticking a box.
# ---------------------------------------------------------------------------
proc swRow(key, label: string; value, wired: bool): SwRow =
  result = SwRow(key: key, label: label, kind: swkToggle, bval: value,
                 fval: 0.0, lo: 0.0, hi: 0.0, implemented: wired,
                 clone: 0'u64, seeded: false)

proc swBuildHostPage(): SwPage =
  ## The host-flags page, read fresh from `aowlspt-host.json` each time it is
  ## built, so it always shows what the file says rather than what the host
  ## happened to latch at boot.
  var rows: seq[SwRow] = @[]
  rows.add swRow("debugUi", "F3 debug panel", readBoolKey("debugUi"), false)
  rows.add swRow("debugEsp", "In-world AI markers", readBoolKey("debugEsp"), false)
  rows.add swRow("botDiag", "Bot registration logging", readBoolKey("botDiag"), false)
  rows.add swRow("unlimitedBots", "Lift the bot cap", readBoolKey("unlimitedBots"), false)
  rows.add swRow("botNav", "Bot navigation API", readBoolKey("botNav"), false)
  rows.add swRow("botAiActivate", "Bot AI activation rescue", readBoolKey("botAiActivate"), false)
  rows.add swRow("osCloseFix", "OS window-close fix", readBoolKey("osCloseFix"), false)
  rows.add swRow("uxVersionBrand", "Brand the version label", readBoolKey("uxVersionBrand"), false)
  rows.add swRow("uxMenuModeText", "Menu corner label", readBoolKey("uxMenuModeText"), false)
  rows.add swRow("settingsUiProbe", "Settings-screen probe", readBoolKey("settingsUiProbe"), false)
  rows.add swRow("settingsRelabelProbe", "Settings relabel proof", readBoolKey("settingsRelabelProbe"), false)
  rows.add swRow("settingsBindProbe", "Settings value read-back", readBoolKey("settingsBindProbe"), false)
  rows.add swRow("settingsPages", "Native mod settings pages", readBoolKey("settingsPages"), false)
  result = SwPage(id: "host", title: "aowlspt - host", rows: rows,
                  stub: false,
                  note: "These are the host's own switches. Every one is read " &
                        "once at boot, so a change here takes effect on the " &
                        "next launch.",
                  renderedFor: 0'u64)

# ---------------------------------------------------------------------------
# The renderer
# ---------------------------------------------------------------------------

proc swFirstControl(tabPtr: Il2CppPtr): Il2CppPtr =
  ## The first readable control on the tab, or nil. This is the object the rest
  ## of the renderer navigates from, and it is the one thing on this screen the
  ## host has PROVEN it can reach: the Phase-1.8 probe walked 25-33 of these per
  ## tab and decoded every label off them.
  result = nil
  if tabPtr == nil or cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) == 0'i32:
    return
  let lst = cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    return
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if arr == nil or size <= 0'i32:
    return
  let n = (if size > int32(cSuiMaxControls): int32(cSuiMaxControls) else: size)
  for i in 0 ..< int(n):
    let slot = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) == 0'i32:
      continue
    let control = cReadPtrAt(slot, 0'i32)
    if control != nil and cIsReadable(control, cSuiOffCtrlValue() + 8'i32) != 0'i32:
      return control

proc swRowContainerGo(tabPtr: Il2CppPtr; why: var string): Il2CppPtr =
  ## The GameObject a NEW ROW must be parented under: the container the tab's
  ## existing rows are children of.
  ##
  ## WHY NOT `_rectTransform`@0x78. That was the previous route and it is dead:
  ## live, on the real screen, it reads null/unreadable, so Phase 3 declined
  ## every time and nothing could ever be rendered. Rather than keep re-guessing
  ## an offset, this walks from an object the host has ALREADY VERIFIED it can
  ## reach and read -- a live SettingControl out of `_createdControls`@0x88,
  ## the list the probe decodes 25-33 correct labels from on every tab.
  ##
  ##   control (a MonoBehaviour, hence a Component)
  ##     -> Component::get_gameObject   -> the row's GameObject
  ##     -> GameObject::get_transform   -> the row's Transform
  ##     -> Transform::get_parent       -> the CONTAINER the rows live in
  ##     -> Component::get_gameObject   -> what SetParentAndAlign wants
  ##
  ## Being the parent of a real row is what makes this the right answer rather
  ## than a plausible one: a new child of that container is a SIBLING of the
  ## stock rows, so the tab's own layout group positions it exactly as it
  ## positions everything else, and it inherits the same canvas by construction.
  ## This is the identical lesson the debug overlay learned the hard way -- reach
  ## a container by walking from a verified live object, never by an offset that
  ## can read null.
  ##
  ## Every hop names itself and its pointer on failure. A silent decline here is
  ## what cost three cycles.
  result = nil
  why = ""
  let control = swFirstControl(tabPtr)
  if control == nil:
    why = "the tab has no readable control in _createdControls (+0x" &
          hexOf(uint64(cSuiOffCreatedCtrls())) & ") to navigate from"
    return
  let fnGo = mi2Fn(Mi2GetGameObject)
  let fnTr = mi2Fn(Mi2GoGetTransform)
  let fnPar = cDuFn(DuGetParent)
  if fnGo == nil or fnTr == nil or fnPar == nil:
    why = "a navigation target did not verify on this build (get_gameObject=" &
          (if fnGo != nil: "OK" else: "REJECTED") & " get_transform=" &
          (if fnTr != nil: "OK" else: "REJECTED") & " get_parent=" &
          (if fnPar != nil: "OK" else: "REJECTED") & ")"
    return
  # THE FAKE-NULL GATE. `cIsReadable` proves the pointer is mapped memory of
  # the right SIZE; it proves nothing about whether the object is a live
  # Unity object. `Component::get_gameObject`, `GameObject::get_transform`
  # and `Transform::get_parent` are IL2CPP internal-call wrappers that
  # dereference `m_CachedPtr` at +0x10 -- and when the native half has been
  # destroyed (Unity's "fake null": readable managed memory, compares equal
  # to null, but the C++ object behind it is gone) that deref faults INSIDE
  # Unity's own code, past every guard `cIsReadable` can offer. `iUnityAlive`
  # (the identical check `inspect.nim`/`modstab.nim` already use for exactly
  # this trap) is the only thing that catches it before the call is made.
  if not iUnityAlive(control):
    why = "control=0x" & hexOf(cast[uint64](control)) &
          " is readable but its native half is gone (fake null); " &
          "Component::get_gameObject would fault on it"
    return
  swCrumbP("STAGE: swRowContainerGo -- Component::get_gameObject(control)",
           control)
  let rowGo = cMi2CallPP(fnGo, control)
  if rowGo == nil or cIsReadable(rowGo, 0x20'i32) == 0'i32:
    why = "Component::get_gameObject(control=0x" &
          hexOf(cast[uint64](control)) & ") gave 0x" &
          hexOf(cast[uint64](rowGo)) & ", which is not readable"
    return
  if not iUnityAlive(rowGo):
    why = "rowGo=0x" & hexOf(cast[uint64](rowGo)) &
          " is readable but its native half is gone (fake null); " &
          "GameObject::get_transform would fault on it"
    return
  swCrumbP("STAGE: swRowContainerGo -- GameObject::get_transform(rowGo)", rowGo)
  let rowT = cMi2CallPP(fnTr, rowGo)
  if rowT == nil or cIsReadable(rowT, 0x20'i32) == 0'i32:
    why = "GameObject::get_transform(rowGo=0x" & hexOf(cast[uint64](rowGo)) &
          ") gave 0x" & hexOf(cast[uint64](rowT)) & ", which is not readable"
    return
  if not iUnityAlive(rowT):
    why = "rowT=0x" & hexOf(cast[uint64](rowT)) &
          " is readable but its native half is gone (fake null); " &
          "Transform::get_parent would fault on it"
    return
  swCrumbP("STAGE: swRowContainerGo -- Transform::get_parent(rowT)", rowT)
  let contT = cDuCallPP(fnPar, rowT)
  if contT == nil or cIsReadable(contT, 0x20'i32) == 0'i32:
    why = "Transform::get_parent(rowT=0x" & hexOf(cast[uint64](rowT)) &
          ") gave 0x" & hexOf(cast[uint64](contT)) &
          " -- the row appears to have no parent, which cannot be right"
    return
  if not iUnityAlive(contT):
    why = "containerT=0x" & hexOf(cast[uint64](contT)) &
          " is readable but its native half is gone (fake null); " &
          "Component::get_gameObject would fault on it"
    return
  swCrumbP("STAGE: swRowContainerGo -- Component::get_gameObject(contT)", contT)
  let contGo = cMi2CallPP(fnGo, contT)
  if contGo == nil or cIsReadable(contGo, 0x20'i32) == 0'i32:
    why = "Component::get_gameObject(containerT=0x" &
          hexOf(cast[uint64](contT)) & ") gave 0x" &
          hexOf(cast[uint64](contGo)) & ", which is not readable"
    return
  okLog "settings pages: row container reached by walking from a live control" &
        " -- control=0x" & hexOf(cast[uint64](control)) &
        " rowGo=0x" & hexOf(cast[uint64](rowGo)) &
        " rowT=0x" & hexOf(cast[uint64](rowT)) &
        " containerT=0x" & hexOf(cast[uint64](contT)) &
        " containerGo=0x" & hexOf(cast[uint64](contGo)) &
        ". New rows become siblings of the stock rows, so the tab's own " &
        "layout group places them."
  result = contGo

proc swAnyDonor(tabPtr: Il2CppPtr; kind: var string): Il2CppPtr =
  ## A donor row when the klass census could not name a toggle.
  ##
  ## The census learns 'toggle' by matching the stock English label
  ## 'Enable VoIP'. On a client whose language is not English -- or on any build
  ## where that row moves or is renamed -- it never learns, `gSwKlassToggle`
  ## stays 0, and Phase 3 declined with `toggleKlass=0x0`. Refusing to draw
  ## anything because one label did not match is a worse answer than drawing a
  ## row cloned from whatever the tab actually has: a row is a row, we relabel
  ## it ourselves, and a row we cannot BIND is still honestly marked as such.
  ##
  ## So: prefer the learned toggle; otherwise take the most common klass on the
  ## tab (settings tabs are mostly toggles and sliders, so the mode is a real
  ## row and not an oddity); otherwise the first control there is.
  result = nil
  kind = "none"
  let byKlass = swFindDonor(tabPtr, gSwKlassToggle)
  if byKlass != nil:
    kind = "learned toggle klass 0x" & hexOf(gSwKlassToggle)
    return byKlass
  # The most common klass on the tab.
  #
  # Counted by a plain double loop over the control list rather than with a
  # scratch table: nimony insists a local be provably initialised before it is
  # read, an `array` of counters is not, and the list is capped at
  # `cSuiMaxControls` anyway -- so the quadratic version is both simpler and
  # bounded by a number the probe has already measured (25-33 in practice).
  var best = 0'u64
  var bestN = 0
  let lst = (if tabPtr != nil and
                cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) != 0'i32:
               cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
             else: nil)
  if lst != nil and cIsReadable(lst, cSuiOffListSize() + 4'i32) != 0'i32:
    let arr = cReadPtrAt(lst, cSuiOffListItems())
    let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
    if arr != nil and size > 0'i32:
      let n = int(if size > int32(cSuiMaxControls): int32(cSuiMaxControls)
                  else: size)
      for i in 0 ..< n:
        let si = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
        if cIsReadable(si, 8'i32) == 0'i32:
          continue
        let ci = cReadPtrAt(si, 0'i32)
        if ci == nil or cIsReadable(ci, cSuiOffCtrlValue() + 8'i32) == 0'i32:
          continue
        let k = cast[uint64](cReadPtrAt(ci, 0'i32))
        if k == 0'u64:
          continue
        var cnt = 0
        for j in 0 ..< n:
          let sj = suiPtrAdd(arr, cSuiOffArrElems() + int32(j) * 8'i32)
          if cIsReadable(sj, 8'i32) == 0'i32:
            continue
          let cj = cReadPtrAt(sj, 0'i32)
          if cj == nil or cIsReadable(cj, cSuiOffCtrlValue() + 8'i32) == 0'i32:
            continue
          if cast[uint64](cReadPtrAt(cj, 0'i32)) == k:
            cnt = cnt + 1
        if cnt > bestN:
          bestN = cnt
          best = k
  if best != 0'u64:
    let byMode = swFindDonor(tabPtr, best)
    if byMode != nil:
      kind = "most common klass 0x" & hexOf(best) & " (" & $bestN &
             " row(s) of it on this tab; the toggle klass was never learned, " &
             "so the donor is chosen by shape rather than by name)"
      return byMode
  let any = swFirstControl(tabPtr)
  if any != nil:
    kind = "the first readable control on the tab (no klass census at all)"
    return any

proc swFindDonor(tabPtr: Il2CppPtr; wantKlass: uint64): Il2CppPtr =
  ## The first control on this tab whose klass is `wantKlass` -- the row we will
  ## copy. Returns nil if the tab has none, which is the correct answer: a page
  ## that needs a toggle cannot be rendered onto a tab that has no toggle to
  ## copy, and rendering something else would be worse than rendering nothing.
  result = nil
  if wantKlass == 0'u64 or tabPtr == nil:
    return
  if cIsReadable(tabPtr, cSuiOffCreatedCtrls() + 8'i32) == 0'i32:
    return
  let lst = cReadPtrAt(tabPtr, cSuiOffCreatedCtrls())
  if lst == nil or cIsReadable(lst, cSuiOffListSize() + 4'i32) == 0'i32:
    return
  let arr = cReadPtrAt(lst, cSuiOffListItems())
  let size = cReadI32At(suiPtrAdd(lst, cSuiOffListSize()))
  if arr == nil or size <= 0'i32:
    return
  let n = (if size > int32(cSuiMaxControls): int32(cSuiMaxControls) else: size)
  for i in 0 ..< int(n):
    let slot = suiPtrAdd(arr, cSuiOffArrElems() + int32(i) * 8'i32)
    if cIsReadable(slot, 8'i32) == 0'i32:
      continue
    let control = cReadPtrAt(slot, 0'i32)
    if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
      continue
    if cast[uint64](cReadPtrAt(control, 0'i32)) == wantKlass:
      return control

proc swCloneRow(donor, parentGo: Il2CppPtr; text: string): Il2CppPtr =
  ## Clone one stock control, put it in the live hierarchy, and label it.
  ## Returns the cloned CONTROL (not its GameObject), or nil if any step
  ## refused. Every step is a byte-verified direct call; none is a shared
  ## generic, so the NULL MethodInfo is safe for all of them.
  result = nil
  let fnInst = mi2Fn(Mi2Instantiate)
  if fnInst == nil or donor == nil:
    return
  if not iUnityAlive(donor):
    warn "settings pages: donor=0x" & hexOf(cast[uint64](donor)) &
         " is readable but its native half is gone (fake null); row '" &
         text & "' is skipped rather than Instantiate()d off it"
    return
  swCrumbP("Object::Instantiate(donor) for row '" & text & "' donor", donor)
  let clone = cMi2CallPS1(fnInst, donor)
  if clone == nil or cIsReadable(clone, cSuiOffCtrlValue() + 8'i32) == 0'i32:
    warn "settings pages: Instantiate returned nothing usable for row '" &
         text & "'; the row is skipped"
    return
  # Into the hierarchy. Without a parent under the Canvas a cloned UI object
  # exists but is not drawn, so this is not cosmetic.
  let fnGo = mi2Fn(Mi2GetGameObject)
  if fnGo == nil or parentGo == nil:
    warn "settings pages: row '" & text & "' has no parent to go under " &
         "(get_gameObject=" & (if fnGo != nil: "OK" else: "REJECTED") &
         " parentGo=0x" & hexOf(cast[uint64](parentGo)) &
         "); the clone is left unparented and is NOT drawn"
  elif not iUnityAlive(clone):
    warn "settings pages: the clone for row '" & text & "' (0x" &
         hexOf(cast[uint64](clone)) & ") is readable but its native half " &
         "is gone (fake null) right after Instantiate; left unparented " &
         "and NOT drawn"
  else:
    swCrumbP("Component::get_gameObject(clone) for row '" & text & "' clone",
             clone)
    let cloneGo = cMi2CallPP(fnGo, clone)
    if cloneGo == nil:
      warn "settings pages: Component::get_gameObject on the clone for row '" &
           text & "' returned null; it cannot be parented or shown"
    elif not iUnityAlive(cloneGo):
      warn "settings pages: cloneGo=0x" & hexOf(cast[uint64](cloneGo)) &
           " for row '" & text & "' is readable but its native half is " &
           "gone (fake null); it cannot be parented or shown"
    else:
      let fnPar = mi2Fn(Mi2SetParentAlign)
      if fnPar != nil:
        swCrumbP("SetParentAndAlign(cloneGo, parentGo) for row '" & text &
                 "' cloneGo", cloneGo)
        cMi2CallVS2(fnPar, cloneGo, parentGo)
      else:
        warn "settings pages: TMP_DefaultControls::SetParentAndAlign did not " &
             "verify on this build; row '" & text & "' cannot be placed"
      let fnAct = mi2Fn(Mi2GoSetActive)
      if fnAct != nil:
        swCrumbP("GameObject::SetActive(true) for row '" & text & "' cloneGo",
                 cloneGo)
        cMi2CallVPB(fnAct, cloneGo, 1'i32)
  # The label, by the SAME setter-first path the relabel now uses: a clone
  # inherits the donor's LocalizedText, which would otherwise put the donor's
  # own localised string back over ours the moment the row is enabled.
  swCrumbP("swControlTmp(clone) -- the label chain for row '" & text &
           "' clone", clone)
  let tmp = swControlTmp(clone)
  if tmp != nil:
    swCrumbP("relabel row '" & text & "' tmp", tmp)
    if swRelabelControl(clone, tmp, text):
      okLog "settings pages: cloned row '" & text & "' (control=0x" &
            hexOf(cast[uint64](clone)) & ") labelled via " & gSwLastRoutes
    else:
      warn "settings pages: the clone for row '" & text & "' could not be " &
           "labelled; it is left showing the donor's text"
  else:
    warn "settings pages: the clone for row '" & text & "' has no reachable " &
         "TMP label; it is left showing the donor's text"
  # ------------------------------------------------------------------
  # AND NOW EVERY OTHER TMP THE ROW CARRIES -- which is where the caption
  # the player actually reads lives.
  #
  # The block above writes exactly ONE TextMeshProUGUI: `swControlTmp` is
  # `control.Text(+0x80) -> LocalizedText -> _labels[0]`. It then logs
  # success, and it is telling the truth about the write it made. It is the
  # wrong TMP.
  #
  # MEASURED LIVE 2026-09-02 (inspector, build 4,758,016, Settings open), on
  # rows this very function produced and acceptance caught still reading
  # 'Interface language':
  #
  #   parent 0x00000203095d3e00 7
  #     Text -> Settings Drop Down(Clone)(Clone) -> Settings -> Viewport
  #          -> Scroll View -> Container -> Game Settings
  #   component 0x00000203095d3e00 LocalizedText -> FOUND 0x00000203091c2210
  #   component 0x00000203095d3f40 LocalizedText -> returned NULL
  #
  # So the TMP that RENDERS is a `Text` CHILD carrying its OWN LocalizedText,
  # while the row control itself has none. `swSetLocalizedText` resolves its
  # target as `control + 0x80`, so every write above went to a component
  # nothing on screen reads, and the child re-localised itself back to the
  # donor's key. That is the whole defect, and no amount of re-applying at
  # the control level can reach it.
  #
  # `modsRelabelRow` is the implementation that does this correctly: it walks
  # every TMP under the clone, resolves the LocalizedText ON EACH TMP'S OWN
  # NODE and calls SetLabelText there, registers each write for the re-assert
  # poll, and then decides success with a check THAT CAN FAIL -- does any TMP
  # under this clone still read the donor's caption. It is reused rather than
  # copied so the two callers cannot drift; `who` keeps the log honest about
  # which feature is speaking. It lives in `modstab.nim`, which is included
  # AFTER this file, and that is fine: this module already forward-calls
  # `iUnityAlive` (inspect.nim, 46 includes later) and nimony resolves
  # top-level procs across the whole module regardless of include order.
  # Nothing is reordered.
  let cloneT = iToTransform(clone)
  let donorT = iToTransform(donor)
  if cloneT == nil or donorT == nil:
    warn "settings pages: row '" & text & "' could not be re-labelled " &
         "across every TMP it carries -- Component::get_transform gave " &
         "clone=0x" & hexOf(cast[uint64](cloneT)) & " donor=0x" &
         hexOf(cast[uint64](donorT)) & ". The single-TMP label above stands, " &
         "and on this build that is the one the player CANNOT see."
  else:
    discard modsRelabelRow(cloneT, donorT, text, clone, "settings pages")
  result = clone

## One-shot: the toggle-seed refusal explains itself once, not once per row
## per tab visit.
var gSwSeedRefused = false

proc swSeedToggle(control: Il2CppPtr; value: bool): bool =
  ## Show `value` on a cloned toggle. Uses `SetIsOnWithoutNotify`, NOT
  ## `set_isOn`: a clone inherits the donor's `onValueChanged` listeners, so the
  ## notifying setter would run the GAME's handler for the stock setting the
  ## donor came from -- with our value. Without-notify repaints and stays quiet.
  result = false
  if control == nil or cIsReadable(control, cSuiOffCtrlValue() + 8'i32) == 0'i32:
    return
  let widget = cReadPtrAt(control, cSuiOffCtrlValue())
  if widget == nil or cIsReadable(widget, cSwOffToggleIsOn() + 4'i32) == 0'i32:
    return
  # THE TYPE CHECK. READABLE IS NOT THE SAME AS BEING A TOGGLE.
  #
  # This faulted every single tab visit, and the cost was out of all proportion
  # to the bug. The donor row is chosen by "most common klass on the tab", which
  # on the Game tab is a DROPDOWN, not a toggle -- the log says so itself
  # ("the toggle klass was never learned"). Seeding a toggle into a dropdown
  # clone called `Toggle::SetIsOnWithoutNotify` on an object with a completely
  # different layout, and it faulted inside the game.
  #
  # The VEH guard caught it and the screen survived, so this looked survivable.
  # It was not. The guard unwinds the WHOLE tab-walk body, so everything after
  # `swRenderPage` was skipped -- including `renderedFor = tabKey`. The
  # re-render guard therefore never armed, and the page cloned itself again on
  # every visit: two 'aowlspt - host' rows on screen after two visits, then
  # four. A caught fault that silently costs a later statement is far more
  # expensive than a crash, because nothing points at it.
  #
  # So: refuse unless the widget's klass IS the learned toggle klass. Not
  # readable -- IDENTICAL. Klass identity is the only type evidence available
  # (the export ABI is token-gated on this build) and it is exactly how `swKlassName` and
  # the Phase 2b reader already decide what a control is.
  let wk = cast[uint64](cReadPtrAt(widget, 0'i32))
  # THE WIDGET IS TYPED AS A WIDGET. `gSwKlassToggle` is the SettingToggle
  # ROW's klass; the object here is the Toggle component the row holds at
  # `cSuiOffCtrlValue()`, a different type, so the two were never equal and
  # this refused every row (MEASURED 2026-09-06, see `gSwKlassToggleWidget`).
  # The widget klass is learned ONCE, by walking its parent chain through the
  # offline name index to UnityEngine.UI.Toggle -- identity, not a caption --
  # and every later widget is compared by pointer equality against that.
  if wk != gSwKlassToggleWidget:
    var chain = ""
    var verdict = -1
    if gSwKlassToggleWidget == 0'u64:
      verdict = swWidgetIsToggle(widget, chain)
      if verdict == 1:
        gSwKlassToggleWidget = wk
        okLog "settings pages: learned the toggle WIDGET klass = 0x" &
              hexOf(wk) & " from its type chain '" & chain & "' -- the " &
              "row's own klass (0x" & hexOf(gSwKlassToggle) & ", the " &
              "SettingToggle control) is a different object and was what " &
              "this used to be compared against; every seed refused on that"
    if wk != gSwKlassToggleWidget:
      if not gSwSeedRefused:
        gSwSeedRefused = true
        okLog "settings pages: NOT seeding a toggle value -- the cloned " &
              "row's widget klass is 0x" & hexOf(wk) & ", which " &
              (if gSwKlassToggleWidget == 0'u64:
                 "does not walk to UnityEngine.UI.Toggle through the name " &
                 "index (chain '" & chain & "', verdict " & $verdict &
                 " where 1=yes 0=no -1=unreadable)"
               else:
                 "is not the learned toggle widget klass 0x" &
                 hexOf(gSwKlassToggleWidget)) &
              ". Calling Toggle::SetIsOnWithoutNotify on a non-toggle " &
              "FAULTS, and the caught fault used to abort the rest of the " &
              "page render. The row is left showing the donor's value."
      return false
  let fn = swFn(SwToggleNoNotify)
  if fn == nil:
    # THE RAW-STORE FALLBACK IS GONE (INTERACTION-LAYER-MAP M3). It stored
    # `m_IsOn@0x120` directly and its own comment conceded "the checkmark will
    # not move until the player clicks it" -- a model that is right while the
    # screen is wrong, reported as success. There is no safe raw version of
    # this write, so the honest outcome is a refusal that says why.
    warn "settings page: Toggle::SetIsOnWithoutNotify @0x55BA440 did not " &
         "byte-verify, so this row's value was NOT applied. The raw " &
         "m_IsOn@0x120 store that used to stand in here has been removed: it " &
         "moved the model and not the checkmark, and reported success either " &
         "way (INTERACTION-LAYER-MAP M3)."
    return false
  # The receiver's TYPE is the whole of the protection for a setter call; the
  # widget is the row's declared value component, so its klass is a fact.
  discard frAdmit("settingspages/toggle", frToggleIsOn(), widget)
  if not frRecvOk("settingspages/toggle", frToggleIsOn(), widget):
    return false
  cSwCallVPB(fn, widget, (if value: 1'i32 else: 0'i32))
  result = true

## THE ENUM ROW, AS A REAL DROPDOWN.
##
## Every step is the DLSS rows' step, reached through the shared nativeui
## helpers rather than copied: `SettingDropDown.DropDown@0xA8`
## (`nuDropDownOf`), the game's own `BaseDropDownBox::Show` dispatched through
## the RECEIVER'S OWN vtable slot 24 (`nuDropDownShow`, six proofs, any of
## which refuses), the index applied and its CAPTION read back off the live
## TMPs (`nuDropDownReseat`), and the value bound one-based through
## `sbdRegisterDropdown`, which writes an INTEGER on SAVE.
##
## Returns false with a reason for every refusal, and the caller demotes the
## row to a labelled stub -- never to a toggle standing in for a choice.
proc swSeedChoice(row: var SwRow; guid: string; clone: Il2CppPtr;
                  why: var string): bool =
  result = false
  why = ""
  if row.choices.len <= 0 or row.choices.len > 16:
    why = "its schema offers " & $row.choices.len & " option(s), outside the " &
          "1..16 the game's own Show accepts"
    return
  swCrumbP("nuDropDownOf for enum row '" & row.key & "' clone", clone)
  let ddb = nuDropDownOf(clone)
  if ddb == nil:
    why = "SettingDropDown.DropDown @0xA8 read null or unreadable on the " &
          "cloned row, so there is no DropDownBox to fill"
    return
  var w2 = ""
  swCrumbP("nuDropDownShow for enum row '" & row.key & "'", ddb)
  if not nuDropDownShow(ddb, row.choices, w2):
    why = "the game's own Show refused -- " & w2
    return
  # ONE-BASED, like every other choice on this host (the config, the F12
  # overlay and `sbdRegisterDropdown` all agree on that and the control is the
  # only zero-based surface).
  var one = int32(row.fval + 0.5)
  if one < 1'i32: one = 1'i32
  if one > int32(row.choices.len): one = int32(row.choices.len)
  var w3 = ""
  let painted = nuDropDownReseat(clone, ddb, row.choices, one, w3)
  if not painted:
    # NOT a refusal of the row: the selection is real and bound. What failed
    # is the CAPTION, and saying so is the whole point -- a silently blank
    # dropdown is exactly the reported defect.
    warn "settings pages: enum row '" & row.key & "' is bound and selects " &
         "option " & $one & " of " & $row.choices.len & ", but its visible " &
         "caption could not be confirmed -- " & w3 &
         ". Reported rather than assumed; the row still works when opened."
  # THE BIND, AND WHY IT IS NOT `sbdRegisterDropdown`.
  #
  # `settingsbind.nim`'s dropdown row flushes `$int(stagedF)` -- a ONE-BASED
  # INTEGER -- because the only schema it has ever served (`mods/dlss`) really
  # does declare numeric choices. An aowlspt `enum` setting does not: its
  # value is the OPTION STRING. Binding these rows there would write `2` into
  # a config key whose owner expects `"High"`, the mod's reader would reject
  # it, and the edit would silently revert on the next read -- exactly the
  # colour-format defect, repeated.
  #
  # So an enum row is read back HERE, by this page, against the value it was
  # seeded with, and what is written is `choiceVals[index-1]`. `seeded` is
  # therefore TRUE (this file owns the row) and `sbdBound` FALSE.
  row.fval = float64(one)
  row.seeded = true
  row.sbdBound = false
  okLog "settings pages: enum row '" & row.key & "' rendered as a REAL " &
        "dropdown -- " & $row.choices.len & " option(s), showing option " &
        $one & " ('" & row.choices[int(one) - 1] & "'), filled by the game's " &
        "own Show through the receiver's own vtable slot 24. Its edit is " &
        "persisted as the OPTION STRING, not as an index."
  result = true

## One-shot, so a full page does not print sixty lines.
var gSwGeomDumped = false

proc swDescribeGo(tag: string; comp: Il2CppPtr) =
  ## Everything about one row that can decide whether it is on screen. Read-only
  ## and every call guarded by the same `duOk`/`cIsReadable` discipline the rest
  ## of this file uses; `comp` is a Component (a SettingControl or a TMP).
  ##
  ## This exists because "rows cloned and labelled" and "the user sees nothing"
  ## are both true at once, and the difference between them is geometry we have
  ## never once looked at. The rule in this codebase is that the client tells
  ## you.
  if comp == nil or cIsReadable(comp, 0x20'i32) == 0'i32:
    okLog "settings pages/geom " & tag & ": component not readable"
    return
  let fnGo = mi2Fn(Mi2GetGameObject)
  let fnTr = mi2Fn(Mi2GoGetTransform)
  if fnGo == nil or fnTr == nil:
    okLog "settings pages/geom " & tag & ": navigation targets unavailable"
    return
  swCrumbP("geom dump " & tag & " get_gameObject", comp)
  let go = cMi2CallPP(fnGo, comp)
  if go == nil or cIsReadable(go, 0x20'i32) == 0'i32:
    okLog "settings pages/geom " & tag & ": no readable GameObject"
    return
  swCrumbP("geom dump " & tag & " get_transform", go)
  let t = cMi2CallPP(fnTr, go)
  okLog "settings pages/geom " & tag & ": comp=0x" & hexOf(cast[uint64](comp)) &
        " go=0x" & hexOf(cast[uint64](go)) &
        " name='" & duNameOf(go) & "'" &
        " activeSelf=" & duDescribeInt(DuGoActiveSelf, go) &
        " activeInHierarchy=" & duDescribeInt(DuGoActiveInHier, go) &
        " layer=" & duDescribeInt(DuGoLayer, go)
  if t != nil and cIsReadable(t, 0x20'i32) != 0'i32:
    okLog "settings pages/geom " & tag & ": rect=[" & duDescribeRect(t) & "]" &
          " anchoredPos=" & duDescribeVec2(DuGetAnchoredPos, t) &
          " sizeDelta=" & duDescribeVec2(DuGetSizeDelta, t) &
          " anchorMin=" & duDescribeVec2(DuGetAnchorMin, t) &
          " pivot=" & duDescribeVec2(DuGetPivot, t) &
          " localPos=" & duDescribeVec3(DuGetLocalPos, t) &
          " localScale=" & duDescribeVec3(DuGetLocalScale, t)
    # Two levels of parent, named. If the clone landed somewhere with a zero
    # rect, or under something inactive, this is where it shows.
    let fnPar = cDuFn(DuGetParent)
    if fnPar != nil:
      swCrumbP("geom dump " & tag & " get_parent", t)
      let p1 = cDuCallPP(fnPar, t)
      if p1 != nil and cIsReadable(p1, 0x20'i32) != 0'i32:
        let p1go = cMi2CallPP(fnGo, p1)
        okLog "settings pages/geom " & tag & ": parent[0]=0x" &
              hexOf(cast[uint64](p1)) & " name='" &
              (if p1go != nil: duNameOf(p1go) else: "") & "'" &
              " activeSelf=" & duDescribeInt(DuGoActiveSelf, p1go) &
              " rect=[" & duDescribeRect(p1) & "]" &
              " localScale=" & duDescribeVec3(DuGetLocalScale, p1)

proc swDumpRowGeometry(donor, clone, parentGo: Il2CppPtr) =
  ## DONOR vs CLONE, side by side. Whatever differs between a row the game drew
  ## and a row we drew is the reason ours is not visible.
  okLog "settings pages/geom: --- donor vs clone, one shot ---"
  swDescribeGo("DONOR(control)", donor)
  swDescribeGo("CLONE(control)", clone)
  let dTmp = swControlTmp(donor)
  let cTmp = swControlTmp(clone)
  if dTmp != nil:
    swDescribeGo("DONOR(label TMP)", dTmp)
  if cTmp != nil:
    swDescribeGo("CLONE(label TMP)", cTmp)
  let fnTr = mi2Fn(Mi2GoGetTransform)
  if parentGo != nil and fnTr != nil and cIsReadable(parentGo, 0x20'i32) != 0'i32:
    swCrumbP("geom dump PARENT get_transform", parentGo)
    let pt = cMi2CallPP(fnTr, parentGo)
    if pt != nil and cIsReadable(pt, 0x20'i32) != 0'i32:
      okLog "settings pages/geom PARENT: go=0x" &
            hexOf(cast[uint64](parentGo)) & " name='" & duNameOf(parentGo) &
            "' rect=[" & duDescribeRect(pt) & "]" &
            " activeSelf=" & duDescribeInt(DuGoActiveSelf, parentGo) &
            " localScale=" & duDescribeVec3(DuGetLocalScale, pt)

# ---------------------------------------------------------------------------
# THE SLICED RENDERER
#
# WHY IT IS SLICED, measured rather than assumed: `modsindex.nim`'s parser now
# reads a mod's schema whole (commit 16a9775) -- `aowl.tarkov` is 949 rows,
# `maps` 61, `sain` 55. The old renderer drew a page inside ONE call, bounded
# by `cSwMaxRows = 48`, which is why that cap read as "a page has 48 rows": it
# was not a safety bound doing its job, it was the reason 901 of aowl.tarkov's
# rows did not exist on screen.
#
# Raising the cap ALONE would have replaced an invisible truncation with a
# visible stall -- 949 `Object::Instantiate` calls and 949 layout participants
# inside one Unity frame. So the render is a state machine on the page instead:
#
#   swRenderPageBegin   once: pick the donor, build the SCROLL HOST, draw the
#                       heading. Nothing else.
#   swRenderPageSlice   every tick: at most `cSwSliceRows` rows AND at most
#                       `cSwSliceMs` of wall clock, whichever binds first.
#                       Rows appear top-down and the page is usable while it
#                       fills, which is the requirement -- not a loading
#                       screen that finishes.
#   swRenderVerdict     once, when the last row lands: the finished-state
#                       check (9b), stated as counts and negatives read off the
#                       live tree.
#
# The two bounds are both mandatory and neither is redundant. A row count
# cannot bound TIME (a row that costs 3 ms is a 72 ms frame), and a clock
# cannot bound how many managed objects one frame creates (rule 7). The worst
# tick ever measured is kept and printed with the verdict, so "one frame
# budget per tick" is a measurement in the log and not a claim in a comment.
# ---------------------------------------------------------------------------

## THE SLICE CLOCK. `gSwSliceWorstMs` is the worst single tick this session
## across every page -- printed with each verdict, because a budget nobody
## reads back is a budget nobody keeps.
var gSwSliceWorstMs = 0'u64
var gSwSliceWorstWhere = ""
var gSwSliceTicks = 0
var gSwSliceOverruns = 0

## THE GRAFT CLOCK, DELIBERATELY SEPARATE FROM THE ROW CLOCK.
##
## The graft (clone a SettingsList, reparent, find its Content) is a one-off
## per page and costs tens of milliseconds; a row costs ~1 ms. Adding the two
## into one number produced the deployed run's most misleading line -- 62 ms
## "instantiating 1 row(s)" -- which reads as "rows cost 62 ms each" and is
## false. Two clocks, two statements, and the row budget is now a statement
## about rows.
var gSwGraftTicks = 0
var gSwGraftMs = 0'u64
var gSwGraftWorstMs = 0'u64
var gSwGraftWorstWhere = ""

## Did ANY page do work on this tick? `swSliceRegistry` stops after the first
## page that did, so one frame pays one budget -- and a graft tick counts as
## work even though it instantiates no row. Without this a tick that grafted
## page 1 would fall through and graft pages 2..11 as well, which is the same
## unbounded frame the slice exists to prevent, wearing the word "slice".
var gSwSliceWorked = false

## THE TAB THE PAGES BELONG TO, remembered so the per-tick drain can BEGIN the
## next page once the current one has finished. Without this, "one page begun
## per tab-built event" would mean eleven trips to the Settings screen to see
## eleven pages. Set only by `swPagesOnTabBuilt`, and re-proved live (readable,
## not a fake null) every time it is used -- a remembered Unity pointer is an
## offer, never a guarantee.
var gSwPagesTabPtr = 0'u64
var gSwPagesTabKey = 0'u64
## Said once: the settings registry is declining pages the MODS
## registry owns. Per-tick would be log spam (rule 7).
var gSwForeignSaid = false

## WHICH REGISTRY A DRAIN IS DRIVING. This used to be a bare `who: string`
## that `modstab.nim` passed as the literals "settings pages" / "mods pages",
## and `swSliceRegistry` then compared that literal to decide whether it was
## allowed to BEGIN the next page. A behavioural switch on a log caption is a
## seam that drifts the first time someone improves the wording, and the
## failure would be silent: pages that simply never begin.
##
## So the two registries are named ONCE, here, and both files use the enum.
## The caption is derived from it and not the other way round.
type
  SwRegistry* = enum
    swRegSettings                ## `gSwPages` -- the Game tab's flat list
    swRegMods                    ## `gModsPages` -- the MODS tab's subtabs

proc swRegName*(r: SwRegistry): string =
  case r
  of swRegSettings: "settings pages"
  of swRegMods: "mods pages"

## FORWARD DECLARATION into `modstab.nim` (included later). The MODS tab's
## pages live in their own per-subtab containers, so beginning one needs that
## file's `gModsSubs`; the drain here only decides WHEN. Returns true if it
## begun a page, in which case this tick's budget is spent.
proc modsAutoBeginNext(pages: var seq[SwPage]): bool

## Also into `modstab.nim`: does the MODS registry currently OWN the `mod:*`
## pages? `gModsPages` is a variable in that file and variables do NOT
## forward-resolve across an include boundary (procs do), so this is a proc.
##
## It decides ownership, and ownership decides who may render: after the MODS
## tab has built, a `mod:*` page that reappears in `gSwPages` (the fetch
## re-stages on its refresh cycle, and `modsettingsrender.nim` registers into
## the settings registry) must NOT be rendered onto the Game tab as well.
proc modsOwnsModPages(): bool

## And the census, which needs BOTH registries and therefore lives where
## `gModsPages` is visible.
proc modsRegistryCensus(where: string)

## How many times the OK form of the census has been said. A failure is always
## printed; a pass is printed the first few times and then counted, because a
## line on every tab-built event is the log spam rule 7 exists to prevent.
var gSwCensusOk = 0
const cSwCensusOkMax = 8

proc swRegistryCensus*(settings, mods: seq[SwPage]; where: string) =
  ## THE OWNERSHIP ASSERTION, stated as numbers that can be wrong.
  ##
  ## A mod page must exist in exactly ONE registry. It used to exist in two --
  ## `modsBuildPages` COPIED it out of `gSwPages`, and a Nim `seq` copy shares
  ## its elements' `rows` buffer, so both copies wrote `rows[i].clone` over
  ## each other and each one's verdict read the other's clones.
  ##
  ## `shared` is computed by looking for a page id that appears in BOTH
  ## registries -- that is the condition which produces the shared buffer, and
  ## it is what this check exists to falsify. For any such id the two `rows[0]
  ## .clone` values are ALSO compared: if the buffer really is shared they are
  ## necessarily equal, so an id collision whose clones differ is a different
  ## (weaker) fault than one whose clones alias, and the line says which.
  ##
  ## NOTE, said plainly rather than implied: this cannot read a seq's buffer
  ## ADDRESS -- nothing in this host takes `addr` of a managed container and
  ## the codegen is not exercised for it. The id-collision test detects exactly
  ## the situation that creates the aliasing, and the clone comparison
  ## corroborates it; it is not a pointer identity proof, and it is not
  ## reported as one.
  var settingsPages = 0
  var modPagesHere = 0
  var i = 0
  while i < settings.len and i < 64:              # rule 4: capped
    if settings[i].modGuid.len > 0: modPagesHere = modPagesHere + 1
    else: settingsPages = settingsPages + 1
    i = i + 1
  # M is MOD pages, not "every page on the MODS tab": that registry also holds
  # the four built-in pages (Interface/Bots/Assets/Diagnostics), which are
  # constructed there and shared with nothing. Counting them as mod pages
  # would make the census's own number a small lie.
  var modPagesThere = 0
  var k = 0
  while k < mods.len and k < 64:                  # rule 4: capped
    if mods[k].modGuid.len > 0: modPagesThere = modPagesThere + 1
    k = k + 1
  var shared = 0
  var aliasing = 0
  var firstShared = ""
  i = 0
  while i < settings.len and i < 64:
    var j = 0
    while j < mods.len and j < 64:
      if settings[i].id == mods[j].id:
        shared = shared + 1
        if firstShared.len == 0: firstShared = settings[i].id
        if settings[i].rows.len > 0 and mods[j].rows.len > 0 and
           settings[i].rows[0].clone == mods[j].rows[0].clone and
           settings[i].rows[0].clone != 0'u64:
          aliasing = aliasing + 1
        break
      j = j + 1
    i = i + 1
  let line = "page registry (" & where & "): " & $settingsPages &
             " settings page(s), " & $modPagesThere & " mod page(s), " &
             $shared & " shared"
  if shared > 0:
    warn line & " -- AND SHARED IS NOT ZERO. '" & firstShared &
         "' is in both registries" &
         (if aliasing > 0: " and " & $aliasing &
            " of them read the SAME rows[0].clone, so the rows buffer really " &
            "is shared: two renderers are writing over each other"
          else: ", though none aliases a clone yet -- it will as soon as both " &
            "render") & ". A mod page must belong to swRegMods and to nothing " &
         "else; " & $modPagesHere & " mod page(s) are still sitting in the " &
         "settings registry."
  elif modPagesHere > 0:
    warn line & " -- no id is in both registries, but " & $modPagesHere &
         " mod page(s) are STILL in the settings registry (over the subtab " &
         "cap, or the MODS tab has not built yet). They are not owned by " &
         "swRegMods and the Game tab will render them."
  else:
    inc gSwCensusOk
    if gSwCensusOk <= cSwCensusOkMax:
      okLog line & " -- every mod page belongs to the mods registry and to " &
            "nothing else, so no rows buffer is reachable from two " &
            "renderers. (pass #" & $gSwCensusOk & " of " & $cSwCensusOkMax &
            " printed; later passes are counted, failures always print.)"

proc swSliceNote(): string =
  "slice clock: " & $gSwSliceTicks & " row tick(s), worst " &
    $gSwSliceWorstMs & " ms" &
    (if gSwSliceWorstWhere.len > 0: " (" & gSwSliceWorstWhere & ")"
     else: "") & ", budget " & $cSwSliceMs & " ms/" &
    $cSwSliceRows & " rows, " & $gSwSliceOverruns & " overrun(s); graft " &
    "clock: " & $gSwGraftTicks & " tick(s), " & $gSwGraftMs & " ms total, " &
    "worst " & $gSwGraftWorstMs & " ms" &
    (if gSwGraftWorstWhere.len > 0: " (" & gSwGraftWorstWhere & ")" else: "") &
    " -- the graft is the per-page scroll clone and is NOT row cost"

proc swGraftRecord(pageId: string; ms: uint64) =
  inc gSwGraftTicks
  gSwGraftMs = gSwGraftMs + ms
  if ms > gSwGraftWorstMs:
    gSwGraftWorstMs = ms
    gSwGraftWorstWhere = "page '" & pageId & "'"
  if ms > cSwSliceMs:
    okLog "settings pages: page '" & pageId & "' GRAFT tick cost " & $ms &
          " ms (the SettingsList clone and reparent), over the " &
          $cSwSliceMs & " ms row budget. Reported as a graft, on its own " &
          "tick, and NOT charged to the first row -- the deployed run " &
          "before this change said '62 ms instantiating 1 row(s)', which " &
          "made a one-off page cost read as a per-row cost."

proc swSliceRecord(pageId: string; ms: uint64; rows: int) =
  inc gSwSliceTicks
  if ms > gSwSliceWorstMs:
    gSwSliceWorstMs = ms
    gSwSliceWorstWhere = "page '" & pageId & "', " & $rows & " row(s)"
  if ms > cSwSliceMs:
    inc gSwSliceOverruns
    # An overrun is reported the first few times and then only counted: a
    # per-tick warning on a slow machine would be exactly the log spam rule 7
    # exists to prevent, and the count plus the worst measurement carries the
    # fact without it.
    if gSwSliceOverruns <= 4:
      warn "settings pages: RENDER SLICE OVERRAN its budget -- page '" &
           pageId & "' spent " & $ms & " ms instantiating " & $rows &
           " row(s), over the " & $cSwSliceMs & " ms budget. The slice still " &
           "stopped at the row it was on; this names a frame that hitched " &
           "rather than hiding it."

proc swRowGeom(row: SwRow; g: var NuGeom): bool =
  ## One rendered row's LIVE geometry, or false. Never reads anything this
  ## file wrote -- the clone pointer is a handle, the rect comes from
  ## `get_rect` on the live RectTransform.
  g = nuNoGeom()
  if row.clone == 0'u64: return false
  let ctrl = cast[Il2CppPtr](row.clone)
  if not duOk(ctrl, 0x20'i32): return false
  let go = iGameObjectOf(ctrl)
  if go == nil: return false
  let rt = nuTransformOf(go)
  if rt == nil: return false
  g = nuReadGeom(rt)
  result = g.ok

proc swRowCaptionNow(row: SwRow): string =
  ## WHAT THIS ROW READS RIGHT NOW, off the live TMP -- never off anything this
  ## file remembers writing. `m_text` at `cSuiOffTmpMText()` through the same
  ## label chain `swControlTmp` validated hop by hop; "" means the caption
  ## could not be read at all, which is INCONCLUSIVE and never a match.
  result = ""
  if row.clone == 0'u64: return
  let ctrl = cast[Il2CppPtr](row.clone)
  if not duOk(ctrl, 0x20'i32): return
  let tmp = swControlTmp(ctrl)
  if tmp == nil: return
  let s = cReadPtrAt(tmp, cSuiOffTmpMText())
  if s == nil: return
  result = suiReadString(s)

proc swRenderVerdict(page: var SwPage) =
  ## THE PER-PAGE RENDER VERDICT. Three outcomes, and it is stated over the
  ## FINISHED PAGE, never over the writes that produced it.
  ##
  ## PASS requires all three, each of which can fail:
  ##   * rendered == the rows the parser produced for this mod, minus the ones
  ##     explicitly SKIPPED as unsafe (which are counted and named, not
  ##     silently dropped) -- a shortfall names the mod and the number;
  ##   * every rendered row's live rect is inside the container's width -- the
  ##     same predicate `pfxScrollVerdict` uses, because a row wider than the
  ##     viewport is clipped whether it is a PostFX row or a mod row;
  ##   * no two consecutive rows have intersecting y ranges -- the "all stacked
  ##     at the same y" signature of a layout group that never rebuilt.
  ##
  ## INCONCLUSIVE is the third outcome and is never a pass: a row whose rect
  ## could not be read was not observed either way, and a page whose container
  ## has no readable rect was not measured at all.
  if page.verdictDone: return
  page.verdictDone = true
  let want = page.rows.len
  let got = page.drawn
  var shortfall = want - page.skipped - got
  if shortfall < 0: shortfall = 0
  # --- geometry, off the live tree ---
  var contW = 0'f32
  var haveCont = false
  if page.renderParent != 0'u64:
    let pgo = cast[Il2CppPtr](page.renderParent)
    if duOk(pgo, 0x20'i32):
      let prt = nuTransformOf(pgo)
      if prt != nil:
        let pg = nuReadGeom(prt)
        if pg.ok and pg.rectW > 1.0'f32:
          contW = pg.rectW
          haveCont = true
  var measured = 0
  var unread = 0
  var tooWide = 0
  var overlaps = 0
  var firstWide = ""
  var firstOverlap = ""
  var prevOk = false
  var prevTop = 0'f32
  var prevBot = 0'f32
  var prevName = ""
  # THE LIVE-TREE CAPTION CENSUS. The finished-state question, asked as a
  # NEGATIVE: how many rows under this page's Content read back a caption that
  # is OURS, and does any still read something else (the donor's -- fact #88)?
  # A count of what we wrote cannot fail; this can.
  var contentKids = 0
  if page.renderParent != 0'u64:
    let pgo2 = cast[Il2CppPtr](page.renderParent)
    if duOk(pgo2, 0x20'i32):
      let prt2 = nuTransformOf(pgo2)
      var kn = 0
      if prt2 != nil and iChildCount(prt2, kn):
        contentKids = kn
  var carry = 0        ## reads the caption this row was given
  var foreign = 0      ## reads SOMETHING ELSE -- the donor's caption
  var mute = 0         ## no readable caption at all: inconclusive, not a pass
  var firstForeign = ""
  var i = 0
  while i < page.rows.len and i < cSwMaxRows:      # rule 4: capped
    if page.rows[i].clone != 0'u64:
      var want = page.rows[i].label
      if not page.rows[i].implemented:
        want = want & cSwNotDone
      let now = swRowCaptionNow(page.rows[i])
      if now.len == 0:
        mute = mute + 1
      elif now == want:
        carry = carry + 1
      else:
        foreign = foreign + 1
        if firstForeign.len == 0:
          firstForeign = "row '" & page.rows[i].key & "' should read '" &
                         want & "' and reads '" & now & "'"
      var g = nuNoGeom()
      if not swRowGeom(page.rows[i], g):
        unread = unread + 1
        prevOk = false
      else:
        measured = measured + 1
        if haveCont and g.rectW > contW + 1.0'f32:
          tooWide = tooWide + 1
          if firstWide.len == 0:
            firstWide = "'" & page.rows[i].label & "' is " & nuF(g.rectW) &
                        " wide inside a " & nuF(contW) & " container"
        # The y range in the PARENT's space: anchoredPosition plus the rect's
        # own origin. Using sizeDelta here would be the stretched-anchor trap
        # `NuGeom` documents -- for a stretched row sizeDelta is an INSET.
        let bot = g.posY + g.rectY
        let top = bot + g.rectH
        if prevOk and top > prevBot + 0.5'f32 and bot < prevTop - 0.5'f32:
          overlaps = overlaps + 1
          if firstOverlap.len == 0:
            firstOverlap = "'" & prevName & "' [" & nuF(prevBot) & ".." &
                           nuF(prevTop) & "] and '" & page.rows[i].label &
                           "' [" & nuF(bot) & ".." & nuF(top) & "]"
        prevOk = true
        prevTop = top
        prevBot = bot
        prevName = page.rows[i].label
    i = i + 1
  let who = "page '" & page.id & "'" &
            (if page.modGuid.len > 0: " (mod " & page.modGuid & ")" else: "")
  let tail = "  [live tree: " & $contentKids & " child(ren) under the page's " &
             "Content, " & $carry & " row(s) read back OUR caption, " &
             $foreign & " read a FOREIGN one, " & $mute &
             " had no readable caption; index asked for " & $want &
             " row(s). " & $page.ticks & " render tick(s). " & swSliceNote() &
             "; scroll host: " &
             (if page.scrollGo != 0'u64: "built"
              else: "NONE -- " & page.scrollWhy) & "]"
  if foreign > 0:
    warn "settings pages RENDER VERDICT FAIL: " & who & " has " & $foreign &
         " row(s) under its Content that read a caption which is NOT the one " &
         "the index gave them -- " & firstForeign &
         ". That is fact #88's signature (the clone kept the donor's " &
         "localised text), read off the live TMP and not off our own write." &
         tail
  elif shortfall > 0:
    warn "settings pages RENDER VERDICT FAIL: " & who & " rendered " & $got &
         " row(s) of the " & $want & " the parser produced (" & $page.skipped &
         " were SKIPPED as unsafe" &
         (if page.lastSkipWhy.len > 0: ", last reason: " & page.lastSkipWhy
          else: "") & "), so " & $shortfall &
         " row(s) of this mod's settings ARE NOT ON SCREEN AT ALL." & tail
  elif tooWide > 0 or overlaps > 0:
    warn "settings pages RENDER VERDICT FAIL: " & who & " rendered all " &
         $got & " row(s), but " & $tooWide &
         " row(s) are wider than the container" &
         (if firstWide.len > 0: " (" & firstWide & ")" else: "") & " and " &
         $overlaps & " consecutive pair(s) have intersecting y ranges" &
         (if firstOverlap.len > 0: " (" & firstOverlap & ")" else: "") &
         " -- rows stacked on each other mean the layout group never " &
         "rebuilt, and a clipped row is unreadable whether or not it exists." &
         tail
  elif measured == 0 or not haveCont:
    warn "settings pages RENDER VERDICT INCONCLUSIVE: " & who & " reports " &
         $got & " rendered row(s), but " &
         (if not haveCont: "the container's own rect could not be read, so " &
            "no width comparison was possible"
          else: "not one row's rect could be read (" & $unread &
            " unreadable)") & ". Nothing was observed; this is NOT a pass." &
         tail
  elif unread > 0 or mute > 0 or carry < got:
    warn "settings pages RENDER VERDICT INCONCLUSIVE: " & who & " -- " &
         $measured & " of " & $got & " rendered row(s) read back inside the " &
         "container with no overlap, but " & $unread &
         " could not have their rect read and " & $mute &
         " could not have their caption read, so only " & $carry & " of " &
         $got & " were observed to carry our text. They were not observed " &
         "either way. This is NOT a pass." & tail
  else:
    okLog "settings pages RENDER VERDICT PASS: " & who & " rendered " & $got &
          " row(s) of " & $want & " parsed (" & $page.skipped &
          " skipped as unsafe); all " & $measured &
          " read back inside the " & nuF(contW) &
          " px container, no consecutive pair overlaps, and all " & $carry &
          " read their OWN caption off the live TMP with none left on the " &
          "donor's." & tail

proc swCaptureDropTemplate(tabPtr: Il2CppPtr; tabName: string) =
  ## LEARN THE DROPDOWN DONOR FROM THE TAB THAT HAS ONE.
  ##
  ## Called for EVERY tab visit, including the ones this feature declines to
  ## render onto -- that is the point. The pages render onto `game`; the only
  ## stock `SettingDropDown` prefab on this screen hangs off `graphics`.
  ##
  ## Every hop is guarded and the result is proved LIVE before it is kept: a
  ## readable pointer is not a live Unity object (`iUnityAlive` is the
  ## fake-null test), and a control we cannot get a GameObject for is not a
  ## control we may Instantiate. A refusal records its reason in
  ## `gSwDropTemplateWhy`, which the BEGUN line prints -- so "no dropdown" is
  ## always a sentence and never a bare 0x0.
  if gSwDropTemplate != 0'u64 or tabName != "graphics" or tabPtr == nil:
    return
  if cIsReadable(tabPtr, cSwGfxDropTemplate + 8'i32) == 0'i32:
    gSwDropTemplateWhy = "GraphicsSettingsTab+0x" &
      hexOf(uint64(cSwGfxDropTemplate)) & " is not readable on this tab " &
      "object, so _dropDownTemplate was never read"
    return
  let tmpl = cReadPtrAt(tabPtr, cSwGfxDropTemplate)
  if tmpl == nil or not duOk(tmpl, 0x20'i32):
    gSwDropTemplateWhy = "GraphicsSettingsTab._dropDownTemplate @0x" &
      hexOf(uint64(cSwGfxDropTemplate)) & " read null or unreadable (it is a " &
      "serialized field -- this is 'asked too early', not a wrong offset)"
    return
  if not iUnityAlive(tmpl):
    gSwDropTemplateWhy = "GraphicsSettingsTab._dropDownTemplate @0x" &
      hexOf(uint64(cSwGfxDropTemplate)) & " is readable but its native half " &
      "is gone (fake null), so cloning it would be a use-after-free"
    return
  let go = iGameObjectOf(tmpl)
  if go == nil or not iUnityAlive(go):
    gSwDropTemplateWhy = "GraphicsSettingsTab._dropDownTemplate @0x" &
      hexOf(uint64(cSwGfxDropTemplate)) & " has no live GameObject, so it is " &
      "not an Instantiate-able control"
    return
  gSwDropTemplate = cast[uint64](tmpl)
  gSwDropTemplateWhy = "GraphicsSettingsTab._dropDownTemplate @0x" &
    hexOf(uint64(cSwGfxDropTemplate)) & " on the Graphics tab"
  if not gSwDropTemplateSaid:
    gSwDropTemplateSaid = true
    okLog "settings pages: DROPDOWN DONOR captured = 0x" &
          hexOf(gSwDropTemplate) & " from " & gSwDropTemplateWhy &
          " (proved live: readable, not a fake null, has a live GameObject). " &
          "The GAME tab, where the pages render, has NO stock dropdown row, " &
          "so the klass census there leaves gSwKlassDropdown at 0 and " &
          "swFindDonor can only return nil -- which is why every page in the " &
          "deployed run logged dropdownDonor=0x0. Enum rows now clone THIS."

proc swRenderPageBegin(tabPtr, parentGo: Il2CppPtr; page: var SwPage): bool =
  ## ONCE PER PAGE. Picks the donor, builds the scroll host, draws the heading,
  ## and stops. No schema row is instantiated here -- that is the slice's job,
  ## so even the very first tick's cost is bounded.
  result = false
  page.begun = false
  page.complete = false
  page.nextRow = 0
  page.drawn = 0
  page.skipped = 0
  page.lastSkipWhy = ""
  page.scrollGo = 0'u64
  page.scrollWhy = ""
  page.grafted = false
  page.graftMs = 0'u64
  page.verdictDone = false
  page.timedOut = false
  page.verdictAt = 0'u64
  page.beganAt = cNowMs()
  page.renderDonorDrop = 0'u64
  page.renderDonorDropWhy = ""
  page.headClone = 0'u64
  page.ticks = 0
  swCrumb("STAGE: swRenderPageBegin -- swAnyDonor for page '" & page.id & "'")
  var donorKind = ""
  let donorToggle = swAnyDonor(tabPtr, donorKind)
  if donorToggle == nil:
    warn "settings pages: DECLINED -- page '" & page.id & "' has no row on " &
         "this tab to clone at all (tabPtr=0x" & hexOf(cast[uint64](tabPtr)) &
         ", learned toggle klass=0x" & hexOf(gSwKlassToggle) &
         "); nothing rendered and nothing written"
    return
  okLog "settings pages: page '" & page.id & "' donor=0x" &
        hexOf(cast[uint64](donorToggle)) & " chosen by " & donorKind &
        "; parent=0x" & hexOf(cast[uint64](parentGo))
  page.renderDonor = cast[uint64](donorToggle)
  page.renderParent = cast[uint64](parentGo)
  # A DROPDOWN DONOR, for `swkChoice` rows. Optional: a tab with no stock
  # dropdown yields zero here and every enum row on this page is demoted to a
  # labelled stub that names the reason. Never substituted with the toggle
  # donor -- a control that renders and cannot select is the defect this
  # repository produces most often.
  #
  # TWO SOURCES, TRIED IN ORDER, AND THE ONE THAT ANSWERED IS NAMED.
  #   1. a stock dropdown ROW on THIS tab (`swFindDonor` on the learned klass);
  #   2. the GRAPHICS tab's `_dropDownTemplate`, captured on an earlier visit
  #      by `swCaptureDropTemplate` -- the same prefab `dlssrows.nim` clones.
  # Source 1 has NEVER answered on the Game tab (there is no stock dropdown
  # there), which is the whole of the deployed run's `dropdownDonor=0x0`.
  let donorDrop = swFindDonor(tabPtr, gSwKlassDropdown)
  if donorDrop != nil:
    page.renderDonorDrop = cast[uint64](donorDrop)
    page.renderDonorDropWhy = "a stock SettingDropDown row on this tab " &
                              "(klass 0x" & hexOf(gSwKlassDropdown) & ")"
  elif gSwDropTemplate != 0'u64 and
       duOk(cast[Il2CppPtr](gSwDropTemplate), 0x20'i32) and
       iUnityAlive(cast[Il2CppPtr](gSwDropTemplate)):
    page.renderDonorDrop = gSwDropTemplate
    page.renderDonorDropWhy = "BORROWED from " & gSwDropTemplateWhy &
      " -- this tab has none of its own"
  else:
    page.renderDonorDropWhy =
      "NONE: this tab has no stock SettingDropDown row, and " &
      (if gSwDropTemplate == 0'u64:
         (if gSwDropTemplateWhy.len > 0: gSwDropTemplateWhy
          else: "the Graphics tab has not been opened this session, so its " &
                "_dropDownTemplate was never offered")
       else: "the borrowed Graphics template no longer reads back as a live " &
             "object") &
      ". Every enum row on this page is a labelled stub"
  page.begun = true
  okLog "settings pages: page '" & page.id & "' BEGUN -- donor and dropdown " &
        "donor captured, nothing instantiated yet. The scroll graft is the " &
        "NEXT tick's work and is clocked separately from the rows; " &
        "dropdownDonor=0x" & hexOf(page.renderDonorDrop) &
        " from " & page.renderDonorDropWhy & "."
  result = true

proc swScheduleVerdict(page: var SwPage) =
  ## Arm the SETTLED verdict (see `cSwVerdictSettleMs`); the registry drain
  ## judges it when due, off the live tree. Every completion path calls this
  ## rather than `swRenderVerdict` directly, so no page is judged on the
  ## frame it finished.
  if page.verdictDone or page.verdictAt != 0'u64:
    return
  page.verdictAt = cNowMs() + cSwVerdictSettleMs

proc swRenderPageGraft(page: var SwPage) =
  ## THE GRAFT, ON ITS OWN TICK. Clones the SettingsList that makes the page
  ## scroll, reparents it, draws the heading, and stops. NO schema row is
  ## instantiated here, which is the whole point: it is the one expensive
  ## step per page and it is now measured as itself.
  ##
  ## EVERY page needs a scroll host. `aowl.tarkov` is 949 rows; in the
  ## authored fixed-height panel rows 20..949 are not "below the fold", they
  ## are unreachable. A page that could not get one is still rendered (a
  ## truncated page beats no page) and says so, in its own warning and again
  ## in its verdict.
  let t0 = cNowMs()
  let parentGo = cast[Il2CppPtr](page.renderParent)
  let donorToggle = cast[Il2CppPtr](page.renderDonor)
  var rowParent = parentGo
  var contentGo: Il2CppPtr = nil
  var scrollNote = ""
  let anchorT = (if parentGo != nil: nuTransformOf(parentGo) else: nil)
  if swScrollHostFor(anchorT, parentGo, contentGo, scrollNote) and
     contentGo != nil:
    rowParent = contentGo
    page.scrollGo = cast[uint64](contentGo)
    okLog "settings pages: page '" & page.id & "' SCROLLS -- rows are " &
          "parented into a cloned SettingsList's Content (the same graft " &
          "postfxrows.nim uses, shared and not copied). " & scrollNote
  else:
    page.scrollWhy = scrollNote
    warn "settings pages: page '" & page.id & "' has NO scroll host -- " &
         scrollNote & ". Its rows go into the fixed-height panel, so any row " &
         "past the bottom edge is UNREACHABLE, not merely off-screen. " &
         $page.rows.len & " row(s) are about to be rendered into it."
  page.renderParent = cast[uint64](rowParent)
  swCrumb("render the heading row for page '" & page.id & "'")
  # THE HEADING CLONE IS KEPT, not discarded. It is the one object a begun
  # page owns before any schema row exists, and the liveness test in
  # `swPagesOnTabBuilt` needs it: without it a page between its graft tick and
  # its first row tick reads as "lost its clones" and is re-begun, forever.
  let headCtrl = swCloneRow(donorToggle, rowParent, page.title)
  if headCtrl != nil:
    page.headClone = cast[uint64](headCtrl)
  page.grafted = true
  page.graftMs = cNowMs() - t0
  swGraftRecord(page.id, page.graftMs)
  if page.stub:
    discard swCloneRow(donorToggle, rowParent, page.note & cSwNotDone)
    page.complete = true
    okLog "settings pages: page '" & page.id & "' is a STUB -- heading and " &
          "note rendered, no rows bound"
    swScheduleVerdict(page)

proc swRenderPageSlice(page: var SwPage): int =
  ## AT MOST ONE FRAME BUDGET OF WORK. Returns rows instantiated this tick.
  ##
  ## Every early exit leaves `nextRow` where it was, so the next tick resumes
  ## at the same row rather than restarting or skipping -- a resumable loop
  ## that silently restarts is how a page renders row 0 forever and reports
  ## progress every time.
  result = 0
  if not page.begun or page.complete: return
  # THE TICK BOUND, CHECKED FIRST. A page that has been granted this many
  # ticks and is still not complete has stopped advancing; it says so, with
  # its shortfall, and stops asking for ticks. This is the bound that CANNOT
  # be reset by a re-begin, which is why it exists alongside the wall clock.
  page.ticks = page.ticks + 1
  if page.ticks > cSwMaxPageTicks:
    page.complete = true
    page.timedOut = true
    var short = page.rows.len - page.skipped - page.drawn
    if short < 0: short = 0
    warn "settings pages RENDER VERDICT TIMEOUT (ticks): page '" & page.id &
         "' has been granted " & $page.ticks & " render tick(s) -- over the " &
         $cSwMaxPageTicks & "-tick bound -- and is STILL NOT COMPLETE. " &
         $page.drawn & " row(s) on screen of " & $page.rows.len & " parsed (" &
         $page.skipped & " skipped), so " & $short & " row(s) are NOT on " &
         "screen. The page stops asking for ticks rather than spinning for " &
         "the rest of the session; re-open the tab to try again. Its " &
         "finished-state verdict follows immediately and is read off the " &
         "live tree, not off these counters."
    swScheduleVerdict(page)
    return
  # THE GRAFT IS A TICK OF ITS OWN, and it is the FIRST thing a begun page
  # does. Returning 0 here is correct and is not "no progress": the registry
  # reads `gSwSliceWorked`, not the row count, precisely so a graft cannot be
  # mistaken for an idle page and cannot be followed by ten more grafts in the
  # same frame.
  if not page.grafted:
    gSwSliceWorked = true
    swRenderPageGraft(page)
    return
  let donorToggle = cast[Il2CppPtr](page.renderDonor)
  let rowParent = cast[Il2CppPtr](page.renderParent)
  if donorToggle == nil or rowParent == nil or
     not duOk(donorToggle, 0x20'i32) or not duOk(rowParent, 0x20'i32):
    page.complete = true
    warn "settings pages: page '" & page.id & "' STOPPED at row " &
         $page.nextRow & " of " & $page.rows.len & " -- its donor or its row " &
         "container is no longer readable (the tab was rebuilt under it). " &
         "The rows drawn so far are left alone; the page is marked complete " &
         "so this does not retry every frame, and re-opening the tab " &
         "re-renders it."
    swScheduleVerdict(page)
    return
  let t0 = cNowMs()
  var thisTick = 0
  gSwSliceWorked = true
  while page.nextRow < page.rows.len and page.nextRow < cSwMaxRows and
        thisTick < cSwSliceRows:
    let i = page.nextRow
    var why = ""
    if not swRowIsSane(page.rows[i], why):
      page.skipped = page.skipped + 1
      page.lastSkipWhy = why
      warn "settings pages: page '" & page.id & "' row " & $i &
           " SKIPPED (not rendered) -- " & why
      page.nextRow = i + 1
      continue
    var text = page.rows[i].label
    if not page.rows[i].implemented:
      text = text & cSwNotDone
    swCrumb("render row " & $i & " of " & $page.rows.len & " ('" & text & "')")
    # WHICH DONOR THIS ROW IS COPIED FROM. An enum row needs a stock
    # `SettingDropDown` to clone; a clone of a toggle has no DropDownBox at
    # 0xA8 and every dropdown call on it would be a read of a different
    # layout. If this tab has no dropdown, the row is demoted here -- before
    # anything is instantiated -- rather than cloned into something it is not.
    var donorForRow = donorToggle
    if page.rows[i].kind == swkChoice:
      if page.renderDonorDrop != 0'u64:
        donorForRow = cast[Il2CppPtr](page.renderDonorDrop)
        if not duOk(donorForRow, 0x20'i32):
          donorForRow = donorToggle
          page.renderDonorDrop = 0'u64
      if page.renderDonorDrop == 0'u64:
        page.rows[i].kind = swkStub
        page.rows[i].implemented = false
        text = page.rows[i].label & cSwNotDone
        warn "settings pages: row '" & page.rows[i].key & "' declares an " &
             "enum and there is no dropdown donor -- " &
             page.renderDonorDropWhy & " (klass census dropdown=0x" &
             hexOf(gSwKlassDropdown) & ", Graphics template=0x" &
             hexOf(gSwDropTemplate) &
             "), so it is drawn as a labelled stub. Nothing was cloned off a " &
             "toggle to stand in for it."
    let clone = swCloneRow(donorForRow, rowParent, text)
    if clone != nil:
      page.rows[i].clone = cast[uint64](clone)
      page.rows[i].relabelled = false
      if page.rows[i].kind == swkToggle:
        swCrumbP("swSeedToggle for row '" & text & "' clone", clone)
        page.rows[i].seeded = swSeedToggle(clone, page.rows[i].bval)
        if page.rows[i].enableRow and page.modGuid.len > 0:
          # THE PER-MOD ENABLED SWITCH, BOUND THE WAY F12 WRITES IT.
          # `sbdRegisterEnable` puts the row on `settingsbind.nim`'s table, so
          # the SAVE gesture queues `POST /aowlspt/mods/toggle/<guid>` (commit
          # 249a843's path) and the V3 ENABLE verdict reads the manager's own
          # answer back. When it refuses, the row stays on this file's own
          # read-back path (`swReadBackPage`) instead -- one writer either
          # way, never two.
          page.rows[i].sbdBound =
            sbdRegisterEnable(page.modGuid, clone, page.rows[i].bval)
          if page.rows[i].sbdBound:
            okLog "settings pages: page '" & page.id & "' ENABLED row bound " &
                  "through sbdRegisterEnable -- its edit goes out on SAVE as " &
                  "POST /aowlspt/mods/toggle/" & page.modGuid &
                  ", and the V3 ENABLE verdict reads the mod manager's own " &
                  "answer back. This row is the FIRST row of the page."
          else:
            warn "settings pages: page '" & page.id & "' ENABLED row is drawn " &
                 "but settingsbind REFUSED to bind it (its reason is logged " &
                 "above as a settings bind fault). The switch falls back to " &
                 "this file's own read-back, which still queues the same " &
                 "toggle -- but there is no V3 ENABLE verdict for it."
      elif page.rows[i].kind == swkChoice:
        # AN ENUM ROW, AS A REAL DROPDOWN. Same mechanism as the DLSS rows:
        # `SettingDropDown.DropDown@0xA8` -> the game's own
        # `BaseDropDownBox::Show` through the receiver's own vtable slot 24,
        # then the ONE-BASED config value seeded through
        # `sbdRegisterDropdown`, which reads it back through the OTHER
        # function (`get_CurrentIndex`).
        var why = ""
        if not swSeedChoice(page.rows[i], page.modGuid, clone, why):
          page.rows[i].kind = swkStub
          page.rows[i].implemented = false
          page.rows[i].seeded = false
          warn "settings pages: row '" & page.rows[i].key & "' declares an " &
               "enum and is DEMOTED to a labelled stub -- " & why &
               ". It is not faked out of a toggle: a control that renders " &
               "and selects nothing is worse than a row that says it is not " &
               "wired."
      elif page.rows[i].kind == swkColor:
        # THE COLOUR WIDGET. Not a clone: there is no colour control on any
        # stock settings tab to clone, so it is BUILT on top of the row's own
        # clone (which supplies the label and the row styling) from nuikit
        # primitives. A build failure is not fatal to the page -- the row stays
        # as a labelled clone, `seeded` stays false, and read-back therefore
        # gives it no vote, exactly like a toggle whose seed refused.
        swCrumbP("cwBuildForRow for row '" & text & "' clone", clone)
        let slot = cwBuildForRow(clone, rowParent, page.rows[i].key,
                                 page.modGuid,
                                 page.rows[i].cr, page.rows[i].cg,
                                 page.rows[i].cb, page.rows[i].ca)
        if slot >= 0'i32:
          page.rows[i].cwIdx = slot + 1'i32     # biased: 0 means "none"
          page.rows[i].seeded = true
        else:
          page.rows[i].cwIdx = 0'i32
          page.rows[i].seeded = false
          warn "settings pages: row '" & page.rows[i].key & "' is a colour " &
               "row and its widget did NOT build (colorwidget logged the " &
               "reason above). The row is drawn and labelled and is bound to " &
               "nothing; no value will be written for it."
      page.drawn = page.drawn + 1
      thisTick = thisTick + 1
      # ONE-SHOT GEOMETRY DUMP. Rows are being cloned and labelled and the user
      # sees nothing, so the next question is WHERE they went -- and that is a
      # question to ask the client, not to reason about. Dump the donor and the
      # first clone side by side; every field the two share is inherited and
      # every field that differs is ours.
      if not gSwGeomDumped:
        gSwGeomDumped = true
        swDumpRowGeometry(donorToggle, clone, rowParent)
    page.nextRow = i + 1
    # THE CLOCK HALF OF THE BUDGET, checked AFTER a row rather than before, so
    # a tick always makes progress -- a budget that can render zero rows is a
    # page that never finishes.
    if cNowMs() - t0 >= cSwSliceMs: break
  let spent = cNowMs() - t0
  if thisTick > 0: swSliceRecord(page.id, spent, thisTick)
  result = thisTick
  if page.nextRow >= page.rows.len or page.nextRow >= cSwMaxRows:
    page.complete = true
    if page.rows.len > cSwMaxRows:
      warn "settings pages: page '" & page.id & "' has " & $page.rows.len &
           " parsed row(s), over the " & $cSwMaxRows & "-row render cap, so " &
           $(page.rows.len - cSwMaxRows) & " row(s) were NOT rendered. Raise " &
           "cSwMaxRows rather than leaving this unsaid."
    # THE COLOUR CHECK, over the finished page. THREE OUTCOMES: no declared
    # colour row at all is INCONCLUSIVE, not a pass.
    var declared = 0
    var stillStub = 0
    var unbound = 0
    var k = 0
    while k < page.rows.len and k < cSwMaxRows:
      if page.rows[k].declaredColor:
        inc declared
        if page.rows[k].kind != swkColor:
          inc stillStub
        elif page.rows[k].cwIdx == 0'i32 or not page.rows[k].seeded:
          inc unbound
      k = k + 1
    if declared == 0:
      okLog "settings pages: page '" & page.id & "' colour check " &
            "INCONCLUSIVE -- this page's schema declared no colour row, so " &
            "nothing was examined. That is not a pass."
    elif stillStub > 0 or unbound > 0:
      warn "settings pages: page '" & page.id & "' colour check FAIL -- of " &
           $declared & " row(s) whose schema declared a colour, " & $stillStub &
           " still render as a plain text/stub row (the value would not " &
           "parse) and " & $unbound & " drew no working widget. THIS IS THE " &
           "REPORTED BUG's SIGNATURE: a colour setting showing its raw value " &
           "as text."
    else:
      okLog "settings pages: page '" & page.id & "' colour check PASS -- all " &
            $declared & " row(s) whose schema declared a colour render a " &
            "bound colour widget; none is left as a stub or a bare text row."
    # THE MOD'S ENABLED STATE, APPLIED TO WHAT WAS JUST DRAWN. Done once the
    # page is complete rather than per-row, because a row cloned before the
    # switch row was read would be left free while its neighbours were blocked.
    swApplyEnableGray(page, "render")
    swScheduleVerdict(page)

proc swRenderPage(tabPtr, parentGo: Il2CppPtr; page: var SwPage): int =
  ## COMPATIBILITY ENTRY POINT, and deliberately NOT a whole-page render any
  ## more: it begins the page and draws the FIRST slice only. Callers that used
  ## to get a finished page now get a page that is visibly filling, and must
  ## drive `swSliceRegistry` from their tick -- `modstab.nim` does.
  ##
  ## Returns rows drawn on this FIRST SLICE, not the page total, and the
  ## distinction matters: reading it as the total is exactly the
  ## check-that-cannot-fail section 9b is about.
  result = 0
  if not swRenderPageBegin(tabPtr, parentGo, page): return
  result = swRenderPageSlice(page)

proc swVerdictWatch(pages: var seq[SwPage]; reg: SwRegistry) =
  ## THE BOUNDED VERDICT. Said once per page visit for a page that has been
  ## filling for longer than `cSwPageVerdictMs` and has not completed --
  ## because the deployed run proved that "print the verdict when the page
  ## completes" prints nothing at all when the page does not.
  ##
  ## It names the SHORTFALL and the elapsed time, and it is a WARNING: a page
  ## still short of its rows after twelve seconds is a player-visible defect
  ## whether or not it eventually finishes.
  let who = swRegName(reg)
  let now = cNowMs()
  var i = 0
  while i < pages.len and i < 32:                 # rule 4: capped
    if pages[i].begun and not pages[i].complete and not pages[i].timedOut and
       pages[i].beganAt > 0'u64 and now - pages[i].beganAt > cSwPageVerdictMs:
      pages[i].timedOut = true
      let want = pages[i].rows.len
      let got = pages[i].drawn
      var short = want - pages[i].skipped - got
      if short < 0: short = 0
      warn "settings pages RENDER VERDICT TIMEOUT (" & who & "): page '" &
           pages[i].id & "'" &
           (if pages[i].modGuid.len > 0: " (mod " & pages[i].modGuid & ")"
            else: "") & " has been filling for " &
           $(now - pages[i].beganAt) & " ms and is STILL NOT COMPLETE -- " &
           $got & " row(s) on screen of " & $want & " parsed (" &
           $pages[i].skipped & " skipped), so " & $short &
           " row(s) of this page are NOT on screen right now. Graft: " &
           (if pages[i].grafted: $pages[i].graftMs & " ms, done"
            else: "NOT RUN YET -- the page has not even been granted its " &
                  "graft tick, which means this registry's drain is not " &
                  "being called") & ". [" & swSliceNote() &
           "] This is the bounded statement the completion verdict could " &
           "never make; the page keeps filling and its own verdict still " &
           "follows if it finishes."
    i = i + 1

proc swAutoBeginNext(pages: var seq[SwPage]): bool =
  ## BEGIN THE NEXT PAGE, ONCE THE PREVIOUS ONE HAS FINISHED, FROM THE TICK.
  ##
  ## `swPagesOnTabBuilt` begins at most ONE page per tab-built event so that a
  ## tab visit costs one graft rather than eleven. This is the other half of
  ## that: the drain begins the next page when -- and only when -- no page is
  ## in flight, so the registry fills one page at a time, each one reaching its
  ## own verdict, without needing eleven trips to the Settings screen.
  ##
  ## Returns true if it begun one (that page's graft is then the next tick's
  ## work, so this call itself instantiates nothing).
  result = false
  if gSwPagesTabPtr == 0'u64 or gSwPagesTabKey == 0'u64: return
  var i = 0
  while i < pages.len and i < 32:                  # rule 4: capped
    if pages[i].begun and not pages[i].complete:
      return                                       # one at a time
    i = i + 1
  # The first page that has not been rendered onto THIS tab object yet AND
  # that this registry actually OWNS. A `mod:*` page belongs to swRegMods once
  # the MODS tab has built it; the fetch re-stages on its refresh cycle and
  # `modsettingsrender.nim` registers into THIS registry, so without this test
  # a mod page would be rendered twice -- once per tab -- over one rows buffer.
  var pick = -1
  var skippedForeign = 0
  let modsOwn = modsOwnsModPages()
  i = 0
  while i < pages.len and i < 32:
    if pages[i].modGuid.len > 0 and modsOwn:
      skippedForeign = skippedForeign + 1
    elif pages[i].renderedFor != gSwPagesTabKey:
      pick = i
      break
    i = i + 1
  if pick < 0:
    if skippedForeign > 0 and not gSwForeignSaid:
      gSwForeignSaid = true
      okLog "settings pages: " & $skippedForeign & " page(s) in the settings " &
            "registry are mod pages that the MODS registry owns, so they are " &
            "NOT rendered onto the Game tab. They are rendered once, on the " &
            "MODS tab, into their own subtab container."
    return
  let tabPtr = cast[Il2CppPtr](gSwPagesTabPtr)
  if not duOk(tabPtr, 0x20'i32) or not iUnityAlive(tabPtr):
    warn "settings pages: the next page cannot be begun from the tick -- the " &
         "remembered SettingsTab 0x" & hexOf(gSwPagesTabPtr) & " no longer " &
         "reads back as a live object. The registry is left where it is; " &
         "re-opening Settings -> Game re-arms it."
    gSwPagesTabPtr = 0'u64
    return
  var why = ""
  let parentGo = swRowContainerGo(tabPtr, why)
  if parentGo == nil:
    warn "settings pages: the next page ('" & pages[pick].id & "') cannot be " &
         "begun from the tick -- the row container is not reachable (" & why &
         "). Nothing was written."
    return
  var pg = pages[pick]
  if not swRenderPageBegin(tabPtr, parentGo, pg):
    pages[pick] = pg
    return
  pg.renderedFor = gSwPagesTabKey
  pages[pick] = pg
  okLog "settings pages: page '" & pages[pick].id & "' BEGUN FROM THE TICK -- " &
        "the previous page finished and its verdict is above. One page fills " &
        "at a time; this one's graft is the next tick's work."
  result = true

proc swSliceRegistry(pages: var seq[SwPage]; reg: SwRegistry): int =
  ## THE PER-TICK DRAIN, over one registry. Read-modify-write per element, for
  ## the aliasing reason `swPagesOnTabBuilt` documents at length: a scalar
  ## field written through `pages[i].field = x` was MEASURED not to persist,
  ## while the `seq` of rows (whose buffer every copy shares) did.
  ##
  ## ONE page per tick, not all of them: the budget is per TICK, and slicing
  ## three pages of 24 rows in one frame is three times the budget wearing the
  ## word "slice".
  result = 0
  swVerdictWatch(pages, reg)
  gSwSliceWorked = false
  # THE SETTLED VERDICT, one page per tick, when its settle has elapsed. Read
  # off the live tree here, on a later frame than the one the page finished
  # on -- see `cSwVerdictSettleMs` for the measured reason.
  let nowV = cNowMs()
  var v = 0
  while v < pages.len and v < 32:                 # rule 4: capped
    if pages[v].verdictAt != 0'u64 and not pages[v].verdictDone and
       nowV >= pages[v].verdictAt:
      var pv = pages[v]
      pv.verdictAt = 0'u64
      swRenderVerdict(pv)
      pages[v] = pv
      gSwSliceWorked = true
      return
    v = v + 1
  # EACH REGISTRY IS ADVANCED BY THE THING THAT KNOWS WHERE ITS PAGES GO.
  # `gSwPages` renders into the Game tab's one row container; `gModsPages`
  # renders into the MODS tab's per-subtab containers, which only
  # `modstab.nim` can reach. Beginning one against the other's parent would
  # put every mod's rows in the wrong place, which is why this dispatches on
  # the enum and not on a caption.
  var begunOne = false
  case reg
  of swRegSettings: begunOne = swAutoBeginNext(pages)
  of swRegMods: begunOne = modsAutoBeginNext(pages)
  if begunOne:
    gSwSliceWorked = true
    return
  var i = 0
  while i < pages.len and i < 32:                 # rule 4: capped
    if pages[i].begun and not pages[i].complete:
      var pg = pages[i]
      let n = swRenderPageSlice(pg)
      pages[i] = pg
      # STOP ON WORK, NOT ON ROWS. A graft tick renders zero rows and is the
      # most expensive tick a page has; reading `n > 0` as "did something"
      # would let one frame graft every page in the registry.
      if gSwSliceWorked or pg.complete:
        result = n
        return
    i = i + 1

proc swApplyEnableGray(page: var SwPage; why: string) =
  ## A DISABLED MOD'S SETTINGS ARE NOT EDITABLE, and they say so the way this
  ## game already says it: the `UiElementBlocker` gray-out, through the exact
  ## primitives the PostFX subtab uses (see the forward declarations above).
  ##
  ## The ENABLED switch itself is never grayed -- graying the one control that
  ## can undo the state is how a mod becomes impossible to switch back on from
  ## this screen.
  ##
  ## THREE OUTCOMES, and the middle one is why this logs at all: `applied` is
  ## rows whose CanvasGroup was driven, `declined` is rows that have no blocker
  ## to drive (legitimate on a prefab instance), and a page where every row
  ## declined is reported as such rather than as a gray-out that worked. A row
  ## that looks editable while its mod is off is the visible bug; a silent
  ## count of zero is the invisible one.
  var free = true
  var haveSwitch = false
  var i = 0
  while i < page.rows.len and i < cSwMaxRows:
    if page.rows[i].enableRow:
      haveSwitch = true
      free = page.rows[i].bval
    i = i + 1
  if not haveSwitch: return
  var applied = 0
  var declined = 0
  i = 0
  while i < page.rows.len and i < cSwMaxRows:
    if not page.rows[i].enableRow and page.rows[i].clone != 0'u64:
      let ctrl = cast[Il2CppPtr](page.rows[i].clone)
      let cg = swRowGrayGroup(ctrl)
      if cg == nil: declined = declined + 1
      elif swRowGraySet(cg, free): applied = applied + 1
      else: declined = declined + 1
    i = i + 1
  if applied == 0 and declined == 0:
    okLog "settings pages: gray-out for '" & page.id & "' (" & why &
          ") examined NO rows -- the page has an enabled switch and no other " &
          "rendered row. Nothing was done and nothing was wrong."
  elif applied == 0:
    warn "settings pages: gray-out for '" & page.id & "' (" & why & ") is " &
         "INCONCLUSIVE -- all " & $declined & " row(s) declined: none of them " &
         "exposes a UiElementBlocker to drive. The mod reads " &
         (if free: "ENABLED" else: "DISABLED") & " and its rows look " &
         "editable either way. This is NOT a working gray-out."
  else:
    okLog "settings pages: gray-out for '" & page.id & "' (" & why & ") -- " &
          $applied & " row(s) set " & (if free: "FREE" else: "BLOCKED") &
          " through UiElementBlocker.Group" &
          (if declined > 0: ", " & $declined & " declined (no blocker on the " &
                            "prefab instance; those rows stay editable)"
           else: "")

proc swHexNib(v: int): string =
  const digits = "0123456789abcdef"
  var n = v
  if n < 0: n = 0
  if n > 15: n = 15
  $digits[n]

proc swColorHex(r, g, b: float32): string =
  ## `#rrggbb`, the exact form `aowl/src/aowlspt/settings.nim`'s
  ## `colorSetting(format=)` reads back and the web picker already writes, so a
  ## value set in game and a value set in the browser are the same string. A
  ## second encoding here would be a second thing to get wrong.
  ##
  ## Clamped, not asserted: these floats come from a pointer position mapped
  ## through a rect, and a value a hair outside 0..1 from float error must
  ## produce `ff`, not wrap to `00`.
  result = "#"
  var ch: seq[float32] = @[]
  ch.add r
  ch.add g
  ch.add b
  var i = 0
  while i < 3:                            # capped by construction
    var v = ch[i]
    if not (v > 0.0'f32): v = 0.0'f32     # NaN-safe: !(v > 0) catches NaN
    if v > 1.0'f32: v = 1.0'f32
    let b255 = int(v * 255.0'f32 + 0.5'f32)
    result = result & swHexNib(b255 div 16) & swHexNib(b255 mod 16)
    i = i + 1

proc swColorChan01(v: float32): string =
  ## One 0..1 component as short decimal text, at the SAME 8-bit resolution the
  ## value is stored at (`swColorNear`). Deliberately not a float printer: a
  ## `0.6200000000000001` written back on every save is the drift the SDK's
  ## `colorSetting` docstring calls out by name.
  var x = v
  if x < 0.0'f32: x = 0.0'f32
  if x > 1.0'f32: x = 1.0'f32
  let n = int((x * 255.0'f32) + 0.5'f32)          # 0..255
  if n == 0: return "0"
  if n == 255: return "1"
  # n/255 to three decimals, integer maths only -- no float formatting.
  let m = (n * 1000 + 127) div 255                # 0..1000, rounded
  var frac = $m
  while frac.len < 3: frac = "0" & frac
  while frac.len > 1 and frac[frac.len - 1] == '0':
    frac = frac[0 .. frac.len - 2]
  "0." & frac

proc swColorText(fmt: string; hasA: bool; r, g, b, a: float32): string =
  ## THE ONE WRITER. Emits the shape the OWNING MOD declared, because the mod's
  ## own reader is the thing that has to parse it back -- writing `#rrggbb` for
  ## every row (what this path did before) silently reverted every `rgb` and
  ## every bare-`hex` setting on its next read. Alpha is emitted only when the
  ## stored value carried one; it is never invented.
  if fmt == cSwColorFmtHex or fmt == cSwColorFmtHexHash:
    let h = swColorHex(r, g, b)                   # always "#rrggbb"
    var body = h[1 .. h.len - 1]
    if hasA:
      let ah = swColorHex(a, a, a)
      body = body & ah[1 .. 2]
    return (if fmt == cSwColorFmtHexHash: "#" & body else: body)
  result = swColorChan01(r) & "," & swColorChan01(g) & "," & swColorChan01(b)
  if hasA: result = result & "," & swColorChan01(a)

proc swJsonQuote(s: string): string =
  ## `modSetQueueWrite` takes a JSON LITERAL, not a bare value -- its own
  ## docstring says so, and the colour path was handing it `#rrggbb`, producing
  ## `{"key":"...","value":#E6463C}`, which is not JSON at all. Colours are
  ## strings on the wire, so they must arrive quoted.
  result = "\""
  for ch in s:                                    # capped: a settings value
    if ch == '"' or ch == '\\': result.add '\\'
    result.add ch
  result.add '"'

proc swColorNear(a, b: float32): bool =
  ## Same 8-bit colour? Compared at the resolution the value is STORED at, not
  ## at float resolution. A drag produces a new float every frame while the
  ## byte it encodes to is unchanged, and comparing floats would POST a write
  ## per frame for a colour that never actually changed.
  let d = a - b
  (if d < 0.0'f32: -d else: d) < (0.5'f32 / 255.0'f32)

proc swReadBackPage(page: var SwPage) =
  ## Read every rendered row's live value and persist the ones the player
  ## changed. This is the half that makes the page a SETTING rather than a
  ## display: the click went through the game's own toggle path, and this is
  ## where the result comes back to us.
  ##
  ## ONLY ROWS THIS PAGE ACTUALLY SEEDED ARE READ. That sentence was already
  ## here and the code did not implement it: it tested `clone != 0` only, and
  ## `seeded` -- set from `swSeedToggle`'s return at render time -- was written
  ## and never read.
  ##
  ## Harmless while every row got seeded. The moment seeding started REFUSING
  ## (a clone whose widget is not a toggle, which is every row on a tab whose
  ## donor is a dropdown), the read-back began comparing our intended value
  ## against the DONOR's value, concluding the player had changed it, and
  ## persisting that into `aowlspt-host.json`. Observed: `uxVersionBrand`
  ## silently flipped true -> false, and a `botNav` key written that the host
  ## does not even read.
  ##
  ## Writing a user's config file from a value we never wrote is the worst
  ## class of bug in this feature -- it is invisible, it survives restarts, and
  ## it makes a FEATURE look broken later for reasons that have nothing to do
  ## with that feature. A row we did not seed has no opinion, so it gets no
  ## vote.
  var i = 0
  while i < page.rows.len:
    if page.rows[i].clone != 0'u64 and page.rows[i].seeded and
       page.rows[i].kind == swkToggle and not page.rows[i].sbdBound:
      # `sbdBound` rows belong to `settingsbind.nim` -- it staged them, it
      # flushes them on SAVE and it states the V3 verdict. Reading one here
      # too would give a single gesture two independent writers, which for the
      # ENABLED switch means toggling the mod twice.
      let control = cast[Il2CppPtr](page.rows[i].clone)
      swCrumbP("read back row '" & page.rows[i].key & "' clone", control)
      var ok = false
      let live = swReadToggle(control, ok)
      if ok and live != page.rows[i].bval:
        okLog "settings pages: row '" & page.rows[i].key & "' changed " &
              swBoolText(page.rows[i].bval) & " -> " & swBoolText(live) &
              " in game"
        if page.rows[i].enableRow:
          # THE MOD'S OWN ENABLED SWITCH. Not a setting: this is the mod
          # manager's selection, and it goes through the F12 panel's own
          # command queue (`POST /aowlspt/mods/toggle/<guid>`), never through
          # `/aowlspt/settings/<guid>`. See `SwRow.enableRow`.
          let rc = overlayModToggle(page.modGuid, live)
          if rc == 1'i32:
            swEnableWatch(page.modGuid, live)
            page.rows[i].bval = live
            # Immediately, so the page reflects the state the player chose
            # rather than waiting on the manager's 1 s confirmation. The
            # verdict above is what says whether that state actually took;
            # this is only the screen keeping up.
            swApplyEnableGray(page, "the switch moved")
          else:
            # The row is NOT updated, so the switch springs back to what is
            # actually true on the next read rather than showing a state
            # nobody applied.
            warn "settings pages: the ENABLED switch for '" & page.modGuid &
                 "' was moved to " & swBoolText(live) & " and NOTHING was " &
                 "sent -- " &
                 (if rc == 0'i32:
                    "the overlay's mod table has no row for that guid"
                  elif rc == -1'i32:
                    "the row is PROTECTED and the manager would refuse it"
                  else:
                    "no backend port is configured, so the overlay is " &
                    "read-only") &
                 ". The switch will read back as the manager's own answer."
        elif page.modGuid.len > 0:
          # A mod page: the file that would change is the mod's, not ours, and
          # it lives across a process boundary -- POST it, and take the value
          # only optimistically (see `modsettingsrender.swModSetDrainPost` for
          # the outcome, which is asserted, not assumed).
          modSetQueueWrite(page.modGuid, page.rows[i].key, swBoolText(live))
          page.rows[i].bval = live
        elif swSetHostFlag(page.rows[i].key, live):
          page.rows[i].bval = live
    elif page.rows[i].kind == swkChoice and page.rows[i].seeded and
         page.rows[i].clone != 0'u64:
      # THE ENUM ROW'S READ-BACK. The index comes from the GAME'S OWN
      # `get_CurrentIndex` on the live DropDownBox -- a different function
      # from the `set_CurrentIndex` that seeded it -- so this is a reading of
      # the finished state and not a comparison against our own write.
      let ctrl = cast[Il2CppPtr](page.rows[i].clone)
      let ddb = nuDropDownOf(ctrl)
      if ddb != nil:
        let (okIdx, zero) = nuDropDownIndex(ddb)
        let one = zero + 1'i32
        if okIdx and one >= 1'i32 and int(one) <= page.rows[i].choiceVals.len and
           float64(one) != page.rows[i].fval:
          let val = page.rows[i].choiceVals[int(one) - 1]
          okLog "settings pages: row '" & page.rows[i].key & "' changed " &
                "option " & $int(page.rows[i].fval) & " -> " & $one &
                " in game (persisted as the option STRING '" & val &
                "', which is what an aowlspt enum setting stores)"
          if page.modGuid.len > 0:
            modSetQueueWrite(page.modGuid, page.rows[i].key, val)
            page.rows[i].fval = float64(one)
          else:
            warn "settings pages: row '" & page.rows[i].key & "' is an enum " &
                 "on a HOST page, and this host has no string-valued flag " &
                 "writer. The selection moved on screen and NOTHING was " &
                 "persisted; said out loud rather than dropped."
    elif page.rows[i].kind == swkColor and page.rows[i].seeded and
         page.rows[i].cwIdx > 0'i32:
      # THE COLOUR ROW'S READ-BACK. Deliberately the same shape as the toggle
      # branch above, including the `seeded` gate, and for the same measured
      # reason: a row we never bound has no opinion, and letting it vote is
      # what silently rewrote `uxVersionBrand` in a previous build.
      #
      # `cwRowColor` reads the LIVE swatch Graphic's `m_Color` back out of the
      # scene -- it does not return the widget's own record of what it last
      # wrote. That distinction is the whole of CLAUDE.md 9b: a comparison
      # against our own write cannot fail, and this feature's ancestor
      # ("0 did not take" for 16 visibly-wrong rows) is the reason it is
      # spelled out here.
      var lr = 0.0'f32
      var lg = 0.0'f32
      var lb = 0.0'f32
      var la = 0.0'f32
      if cwRowColor(page.rows[i].cwIdx - 1'i32, lr, lg, lb, la):
        if not swColorNear(lr, page.rows[i].cr) or
           not swColorNear(lg, page.rows[i].cg) or
           not swColorNear(lb, page.rows[i].cb):
          let was = swColorHex(page.rows[i].cr, page.rows[i].cg,
                               page.rows[i].cb)
          # The LOG line stays `#rrggbb` (one readable form for a human), but
          # what is PERSISTED is the mod's own declared shape.
          let nowLog = swColorHex(lr, lg, lb)
          let now = swColorText(page.rows[i].cfmt, page.rows[i].cHasA,
                                lr, lg, lb, page.rows[i].ca)
          okLog "settings pages: row '" & page.rows[i].key & "' changed " &
                was & " -> " & nowLog & " in game (persisted as " &
                (if page.rows[i].cfmt.len > 0: page.rows[i].cfmt
                 else: cSwColorFmtRgb) & ": " & now & ")"
          if page.modGuid.len > 0:
            # THE ONLY PERSISTENCE PATH, and the one that matters: this POSTs
            # to `/aowlspt/settings/<guid>`, which is what runs the mod's
            # `onSettingsApplied`. A value stored without that hook changes a
            # file and nothing else -- the setting appears to work and does
            # nothing, which is worse than a row that says it is not wired.
            modSetQueueWrite(page.modGuid, page.rows[i].key, swJsonQuote(now))
            page.rows[i].cr = lr
            page.rows[i].cg = lg
            page.rows[i].cb = lb
          else:
            # A HOST page. `swSetHostFlag` writes a BOOL and there is no string
            # equivalent on this path, so there is nothing here that could
            # honestly persist a colour. Say so once per change rather than
            # dropping the edit silently -- and do NOT update the row, so the
            # widget keeps showing what is actually stored.
            warn "settings pages: row '" & page.rows[i].key & "' is a colour " &
                 "on a HOST page (modGuid empty). The host config writer takes " &
                 "a bool only, so this edit is NOT persisted. Colour settings " &
                 "belong on a mod page, where the write goes through " &
                 "onSettingsApplied."
    i = i + 1

## ---------------------------------------------------------------------------
## LIFECYCLE -- what we rendered onto ONE tab must not still be on screen while
## a DIFFERENT tab is displayed.
##
## MEASURED, live, on the user's client (host log, one settings-screen visit):
##
##   entry #5 tab='game'     tabPtr=0x21e5927bdc0 renderedFor=0x21e5927bdc0
##                                                row0.clone=0x21ff4589300
##   entry #6 tab='graphics' tabPtr=0x21e59239c60 renderedFor=0x21e5927bdc0
##                                                row0.clone=0x21ff4589300
##   DECLINED -- pages render only onto the Game tab and this is 'graphics'
##
## The DECLINE is correct and always was: we do not RENDER onto graphics. What
## was missing is the other half of the lifecycle -- nothing ever took the Game
## tab's rows back OFF when graphics came up. The clones stayed parented into a
## container the Graphics panel still lays out, so the player saw a block of
## blank rows and the real graphics content pushed halfway down the page.
##
## `renderedFor != tabKey` is precisely that condition, it was already being
## computed for the diagnostic above, and it was never acted on. It is now.
##
## HIDDEN, NEVER DESTROYED. Same discipline as the postfx subtab: a clone we
## destroyed is a clone we must rebuild, and `swRenderPage`'s re-render path is
## driven off `clone` still reading back live. Destroying here would make every
## tab switch a full re-clone, which is the row-accumulation bug wearing a hat.
proc swRowGoLive(row: SwRow): Il2CppPtr =
  ## The row clone's GameObject, or nil. THREE guards, not one, and the order
  ## matters: `clone` is a raw `uint64` that outlives the object it names, so
  ## `cIsReadable` proves only that the page is still mapped, and `iUnityAlive`
  ## is the only one of the three that separates a live UI object from Unity's
  ## FAKE NULL (a managed shell whose native half is gone -- readable, non-nil,
  ## and fatal to call into). Never dereference a stored clone handle with
  ## fewer than all three.
  result = nil
  if row.clone == 0'u64:
    return
  let ctrl = cast[Il2CppPtr](row.clone)
  if cIsReadable(ctrl, 8'i32) == 0'i32 or not iUnityAlive(ctrl):
    return
  let go = duGameObjectOf(ctrl)
  if go == nil or not iUnityAlive(go):
    return
  result = go

proc swPageDriveActive(page: SwPage; on: bool; drove, refused: var int) =
  ## `GameObject::SetActive(on)` on every live row clone of `page`. Read-only
  ## with respect to the GAME's own objects: every object touched here is one
  ## this host cloned, and the only thing written is its active state.
  drove = 0
  refused = 0
  let fnAct = mi2Fn(Mi2GoSetActive)
  if fnAct == nil:
    refused = page.rows.len
    return
  var r = 0
  while r < page.rows.len and r < cSwMaxRows:      # rule 4: capped iteration
    if page.rows[r].clone != 0'u64:
      let go = swRowGoLive(page.rows[r])
      if go != nil:
        cMi2CallVPB(fnAct, go, (if on: 1'i32 else: 0'i32))
        drove = drove + 1
      else:
        refused = refused + 1
    r = r + 1

proc swPageCountActive(page: SwPage; active, incon: var int) =
  ## READ BACK `activeInHierarchy` off the live tree. Not `activeSelf`, and not
  ## anything this host wrote a moment ago: the question the player's screen
  ## answers is whether the object is DRAWN, and an ancestor being off decides
  ## that just as much as our own write does.
  ##
  ## `incon` is the third outcome and it is load-bearing. A row whose getter did
  ## not come back has not been shown to be hidden; folding that into `active=0`
  ## would be a check that cannot fail.
  active = 0
  incon = 0
  var r = 0
  while r < page.rows.len and r < cSwMaxRows:
    if page.rows[r].clone != 0'u64:
      let go = swRowGoLive(page.rows[r])
      if go == nil:
        incon = incon + 1
      else:
        var ok = false
        let v = duGetInt(DuGoActiveInHier, go, ok)
        if not ok:
          incon = incon + 1
        elif v != 0'i32:
          active = active + 1
    r = r + 1

## Once per session the lifecycle explains itself; the VERDICT line below is
## emitted on every tab change, because it is the falsifiable one.
var gSwLifeSaid = false
var gSwLifeVerdicts = 0

proc swPagesEnforceTabOwnership(tabKey: uint64; tabName: string) =
  ## THE BUG-1 FIX AND ITS ACCEPTANCE TEST, in that order.
  ##
  ## Every page whose `renderedFor` names a DIFFERENT tab object than the one
  ## now displayed is switched off; every page whose `renderedFor` names THIS
  ## tab is switched back on (a tab the player returns to must get its rows
  ## back, and `swPagesOnTabBuilt`'s "still rendered, nothing to rebuild" fast
  ## path would otherwise leave them hidden forever after one excursion).
  ##
  ## Then the FALSIFIABLE NEGATIVE, stated as a count and read off the live
  ## tree AFTER the writes, never from the writes themselves:
  ##
  ##     no element whose `renderedFor` differs from the currently active tab
  ##     is active in the hierarchy      -> violations must be 0
  ##
  ## What would falsify a PASS: a single foreign row still reading
  ## `activeInHierarchy=1`. What makes it INCONCLUSIVE: a row whose getter did
  ## not come back, so it was not observed either way. "I could not look" is not
  ## a pass.
  var hidPages = 0
  var hidRows = 0
  var showPages = 0
  var showRows = 0
  var refused = 0
  var i = 0
  while i < gSwPages.len and i < 32:
    if gSwPages[i].renderedFor != 0'u64:
      var drove = 0
      var ref2 = 0
      if gSwPages[i].renderedFor != tabKey:
        swPageDriveActive(gSwPages[i], false, drove, ref2)
        if drove > 0: hidPages = hidPages + 1
        hidRows = hidRows + drove
      else:
        swPageDriveActive(gSwPages[i], true, drove, ref2)
        if drove > 0: showPages = showPages + 1
        showRows = showRows + drove
      refused = refused + ref2
    i = i + 1
  # THE READBACK. Separate loop on purpose: it must see the finished state of
  # the whole registry, not the state midway through driving it.
  var violations = 0
  var incon = 0
  var foreignRows = 0
  i = 0
  while i < gSwPages.len and i < 32:
    if gSwPages[i].renderedFor != 0'u64 and gSwPages[i].renderedFor != tabKey:
      var act = 0
      var inc2 = 0
      swPageCountActive(gSwPages[i], act, inc2)
      violations = violations + act
      incon = incon + inc2
      var r = 0
      while r < gSwPages[i].rows.len and r < cSwMaxRows:
        if gSwPages[i].rows[r].clone != 0'u64:
          foreignRows = foreignRows + 1
        r = r + 1
    i = i + 1
  if not gSwLifeSaid and (hidRows > 0 or showRows > 0):
    gSwLifeSaid = true
    okLog "settings pages: LIFECYCLE armed -- rows are rendered onto the Game " &
          "tab and are now SetActive(false) whenever a different tab object is " &
          "displayed, and SetActive(true) again on return. Hidden, never " &
          "destroyed. This is what was leaving Game-tab rows sitting in the " &
          "Graphics layout as blank space with the real content pushed below."
  if foreignRows == 0 and hidRows == 0 and showRows == 0:
    return                    # nothing rendered anywhere yet; nothing to judge
  inc gSwLifeVerdicts
  if gSwLifeVerdicts <= 12:
    if violations > 0:
      warn "settings pages LIFECYCLE VERDICT FAIL: " & $violations & " of " &
           $foreignRows & " row clone(s) rendered for a DIFFERENT tab are still " &
           "activeInHierarchy while tab '" & tabName & "' (0x" & hexOf(tabKey) &
           ") is displayed. Those are the blank rows on screen. Hid " &
           $hidRows & " row(s) across " & $hidPages & " page(s) this pass; " &
           $refused & " clone(s) were unreachable."
    elif incon > 0:
      warn "settings pages LIFECYCLE VERDICT INCONCLUSIVE: 0 foreign row(s) " &
           "read back active, but " & $incon & " of " & $foreignRows &
           " could not be read at all (dead handle or the getter did not " &
           "return), so they were not observed either way. This is NOT a pass. " &
           "Tab '" & tabName & "', hid " & $hidRows & " row(s), showed " &
           $showRows & "."
    else:
      okLog "settings pages LIFECYCLE VERDICT PASS: 0 of " & $foreignRows &
            " row clone(s) rendered for another tab are activeInHierarchy " &
            "while tab '" & tabName & "' is displayed; " & $showRows &
            " row(s) belonging to THIS tab are shown. Hid " & $hidRows &
            " row(s) across " & $hidPages & " page(s) this pass. Read back off " &
            "the live GameObjects, not from the writes."

proc swPagesOnTabBuilt(tabPtr: Il2CppPtr; tabName: string; revisit: bool) =
  ## Phase 3, driven off the same ShowScreen postfix everything else here uses.
  ##
  ## Pages are rendered onto ONE tab (`game`), not spread across the stock tabs:
  ## a mod's settings do not belong under Sound, and putting them all in one
  ## place is what the player asked for. A tab of our own would be the right
  ## answer and needs a `SettingsTab` we cannot construct -- see the note at the
  ## top of this file about shared generics.
  ##
  ## EVERY early return announces itself. The previous build's worst failure
  ## mode was this feature doing nothing AND saying nothing: the banner printed
  ## at boot, the hook demonstrably fired (Phase 2a/2b logged on the same
  ## postfix), and across a full pass of every tab there was not one page line,
  ## not one clone line and not one fault line. A path that declines must say
  ## why, or it cannot be debugged from a log at all.
  # THE INDEX-BINDING GATE, before anything here calls `cDuFn(DuGetParent)`.
  #
  # This module indexes `aowl_du_targets` POSITIONALLY with constants declared
  # in debugui.nim, and until now nothing checked that binding on this path --
  # only `bindDebugUi` did, and this feature runs whether or not debugui is
  # flagged on. A row inserted into the middle of that C table would therefore
  # reach the live client through HERE as a byte-verified function of the wrong
  # shape, called with the wrong frame: precisely the 2026-08-24 defect
  # (`DuGetParent` -> `Transform::set_localPosition`), just through a door the
  # fix did not cover. `duTargetsBindOk` is memoised, so this costs one compare
  # after debugui has already asked.
  if not duTargetsBindOk():
    warn "settings pages: the managed-target index binding self-check FAILED " &
         "(see the debugui line above naming the offending index). This " &
         "module calls aowl_du_targets by POSITION, so every call would be " &
         "to the wrong method. NOT rendering."
    return
  if gSwPagesOn:
    inc gSwPagesFires
    if gSwPagesFires <= 8:
      okLog "settings pages: entry #" & $gSwPagesFires & " tab='" & tabName &
            "' tabPtr=0x" & hexOf(cast[uint64](tabPtr)) &
            " on=" & (if gSwPagesOn: "true" else: "false") &
            " off=" & (if gSwOff: "true" else: "false") &
            " pages=" & $gSwPages.len &
            # THE RE-RENDER DIAGNOSTIC. Rows were observed accumulating -- two
            # 'aowlspt - host' rows on screen after two tab visits -- while the
            # "lost its clones" branch never logged, which means the
            # `renderedFor == tabKey` test was false on the SECOND visit even
            # though the first visit ended by assigning exactly that. So print
            # what the registry actually holds on entry: if renderedFor is 0
            # here after a render, the assignment did not persist into the seq
            # and the guard can never fire.
            (if gSwPages.len > 0:
               " renderedFor=0x" & hexOf(gSwPages[0].renderedFor) &
               " row0.clone=0x" &
               (if gSwPages[0].rows.len > 0: hexOf(gSwPages[0].rows[0].clone)
                else: "-")
             else: "") &
            " toggleKlass(before census)=0x" & hexOf(gSwKlassToggle)
  if swVisitBlocked():
    if gSwPagesOn and gSwPagesFires <= 8:
      okLog "settings pages: DECLINED -- " &
            (if gSwOff: "the SESSION fault ceiling has been reached; nothing " &
                        "further is rendered this session"
             else: "this TAB VISIT has spent its fault budget; re-open the " &
                   "tab to try again (the feature is still armed)")
    return
  if not gSwPagesOn:
    return                              # flag off: silence is the correct answer
  if tabPtr == nil:
    okLog "settings pages: DECLINED -- the tab pointer was nil"
    return
  let tabKey = cast[uint64](tabPtr)
  # LIFECYCLE FIRST, BEFORE ANY DECLINE. This runs for EVERY tab, including the
  # ones we refuse to render onto -- that is the whole point. The old code
  # returned out of the `tabName != "game"` branch below with the Game tab's
  # clones still parented and still active, which is Bug 1.
  swPagesEnforceTabOwnership(tabKey, tabName)
  # LEARN THE DROPDOWN DONOR FROM WHICHEVER TAB HAS ONE. Before the Game-tab
  # filter below, deliberately: the tab that carries `_dropDownTemplate` is
  # `graphics`, which this feature never renders onto.
  swCaptureDropTemplate(tabPtr, tabName)
  if tabName != "game":
    if gSwPagesFires <= 8:
      okLog "settings pages: DECLINED -- pages render only onto the Game tab " &
            "and this is '" & tabName & "' (expected; open Settings -> Game). " &
            "Anything previously rendered for another tab has been hidden by " &
            "the lifecycle pass above; see its VERDICT line for the count."
    return
  # Learn the widget-klass census OURSELVES rather than relying on Phase 2
  # having been switched on. Phase 3 previously depended on `settingsRelabel
  # Probe`/`settingsBindProbe` for its klass pointers without saying so, which
  # meant `settingsPages` alone could only ever decline.
  swCrumb("STAGE: swPagesOnTabBuilt -- swLearnTabKlasses tab=" & tabName)
  swLearnTabKlasses(tabPtr)
  if gSwPagesFires <= 8:
    okLog "settings pages: after the census on this same tab visit -- " &
          "toggle=0x" & hexOf(gSwKlassToggle) &
          " float=0x" & hexOf(gSwKlassFloat) &
          " dropdown=0x" & hexOf(gSwKlassDropdown) &
          " select=0x" & hexOf(gSwKlassSelect) &
          ". A zero here means the stock anchor label for that type was not " &
          "found on this tab (a non-English client will do that), which is why " &
          "the donor is no longer required to be a learned toggle."
  # PICK UP ANY MOD PAGES THE FETCH THREAD STAGED. This is the Unity main
  # thread and the only writer of `gSwPages` from a fetch; see the forward
  # declaration at the top of this file for why the fetch thread no longer
  # registers directly. It runs BEFORE the emptiness test below so a staged mod
  # page counts as a non-empty registry.
  swCrumb("STAGE: swPagesOnTabBuilt -- modSetDrainStaged")
  modSetDrainStaged()
  # THE OWNERSHIP ASSERTION, right after the only place this registry grows.
  modsRegistryCensus("settings tab built")
  # The registry is rebuilt from the config each time the tab is opened, so the
  # rows show what the file currently says.
  if gSwPages.len == 0:
    swPageRegister(swBuildHostPage())
    okLog "settings pages: registry was empty; built the host page -> " &
          $gSwPages.len & " page(s), " &
          (if gSwPages.len > 0: $gSwPages[0].rows.len else: "0") & " row(s)"
  if gSwPages.len == 0:
    warn "settings pages: DECLINED -- the page registry is STILL empty after " &
         "building the host page. Nothing can be rendered; this is a host bug, " &
         "not a game one, and nothing was written to the settings screen."
    return
  # REMEMBERED FOR THE TICK, so the drain can begin page N+1 when page N is
  # done rather than waiting for another tab visit. See `swAutoBeginNext`.
  gSwPagesTabPtr = tabKey
  gSwPagesTabKey = tabKey
  var i = 0
  # ---- ONE PAGE IS BEGUN PER TAB-BUILT EVENT, AND NEVER ONE THAT IS ALREADY
  # RENDERING. MEASURED 2026-09-04 (host log, entries #7..#18, 11 pages between
  # [1:05:07] and [1:05:11]):
  #
  #   * this loop called `swRenderPage` -- which is BEGIN plus one slice -- for
  #     EVERY page in the registry inside ONE call. Each page's slice spends
  #     that tick on its GRAFT (a SettingsList clone, measured 265 ms), so the
  #     whole loop was 11 grafts back to back: a ~3.2 s stall on the Unity main
  #     thread, wearing the word "slice", and exactly one row per page (the
  #     heading) ever drawn;
  #   * `swRenderPageBegin` resets `beganAt`, `verdictDone`, `ticks`, `drawn`
  #     and `nextRow`. Re-beginning every page on every tab-built event
  #     therefore reset the verdict deadline faster than it could expire, which
  #     is why a 65-minute run printed NOT ONE `RENDER VERDICT` line;
  #   * and the liveness test that decided to re-render scanned `rows[].clone`
  #     only. A page between its graft tick and its first row tick owns no row
  #     clone, so the test said "lost its clones" for a perfectly healthy page,
  #     every time -- the log's `row0.clone=0x0` on every entry line is that.
  #
  # So: a page that is BEGUN and not COMPLETE is IN FLIGHT and is left alone --
  # `swSliceRegistry` owns it and will finish it and state its verdict. A page
  # that has never been begun is begun only if nothing else is in flight, which
  # bounds a tab-built event to at most ONE graft.
  var inFlight = -1
  var f = 0
  while f < gSwPages.len and f < 32:               # rule 4: capped
    if gSwPages[f].begun and not gSwPages[f].complete:
      inFlight = f
      break
    f = f + 1
  var begunThisCall = false
  while i < gSwPages.len:
    swCrumb("STAGE: swPagesOnTabBuilt -- page[" & $i & "/" & $gSwPages.len &
            "] id='" & gSwPages[i].id & "' rows=" & $gSwPages[i].rows.len)
    # NOT OURS: a `mod:*` page belongs to the MODS registry once that tab has
    # built it, and rendering it here as well would be two renderers over one
    # shared rows buffer (see `swRegistryCensus`). Read-back is still ours to
    # do -- the value the player left is the same value either way.
    if gSwPages[i].modGuid.len > 0 and modsOwnsModPages():
      swReadBackPage(gSwPages[i])
      i = i + 1
      continue
    # IN FLIGHT: the drain owns it. Reading its values back is safe and is
    # still wanted; re-beginning it is what produced the 4-second cycle.
    if gSwPages[i].begun and not gSwPages[i].complete:
      swReadBackPage(gSwPages[i])
      i = i + 1
      continue
    # Read back BEFORE deciding whether to re-render, so a value the player
    # changed is captured even on the pass that decides to rebuild the page.
    if gSwPages[i].renderedFor == tabKey:
      swReadBackPage(gSwPages[i])
      # Still rendered into this same tab object; nothing to rebuild. A clone
      # that has been destroyed under us reads unreadable, and that is what
      # forces a re-render.
      #
      # THREE THINGS COUNT AS A LIVE CLONE, not one: any row clone, the HEADING
      # clone, or the scroll host. The heading and the scroll host are what a
      # page owns before its first row exists, and omitting them is what made
      # this test unable to answer anything but "lost".
      var alive = false
      if gSwPages[i].headClone != 0'u64 and
         cIsReadable(cast[Il2CppPtr](gSwPages[i].headClone), 8'i32) != 0'i32:
        alive = true
      if not alive and gSwPages[i].scrollGo != 0'u64 and
         cIsReadable(cast[Il2CppPtr](gSwPages[i].scrollGo), 8'i32) != 0'i32:
        alive = true
      var r = 0
      while not alive and r < gSwPages[i].rows.len and r < cSwMaxRows:
        if gSwPages[i].rows[r].clone != 0'u64 and
           cIsReadable(cast[Il2CppPtr](gSwPages[i].rows[r].clone), 8'i32) != 0'i32:
          alive = true
          break
        r = r + 1
      if alive:
        i = i + 1
        continue
      okLog "settings pages: page '" & gSwPages[i].id & "' lost its clones " &
            "(the tab was rebuilt under it) -- no row clone, no heading " &
            "clone (0x" & hexOf(gSwPages[i].headClone) & ") and no scroll " &
            "host (0x" & hexOf(gSwPages[i].scrollGo) &
            ") is readable; re-rendering"
    # THE ONE-BEGIN BOUND. Everything past here BEGINS a page, which costs a
    # graft tick; at most one of those per tab-built event.
    if begunThisCall or inFlight >= 0:
      if gSwPagesFires <= 8:
        okLog "settings pages: page '" & gSwPages[i].id &
              "' is NOT begun on this tab-built event -- " &
              (if begunThisCall: "another page was already begun in this call"
               else: "page '" & gSwPages[inFlight].id &
                     "' is still filling (" & $gSwPages[inFlight].drawn &
                     " of " & $gSwPages[inFlight].rows.len & " rows)") &
              ". One page renders at a time and swSliceRegistry finishes it; " &
              "beginning all of them here cost ~3.2 s of Unity main thread " &
              "per tab visit and let no page reach its verdict."
      i = i + 1
      continue
    var why = ""
    let parentGo = swRowContainerGo(tabPtr, why)
    if parentGo == nil:
      warn "settings pages: DECLINED -- could not reach the row container (" &
           why & "); page '" & gSwPages[i].id &
           "' is not rendered (nothing was written)"
      i = i + 1
      continue
    # READ, MUTATE, WRITE BACK -- do not mutate `gSwPages[i]` in place.
    #
    # `gSwPages[i].renderedFor = tabKey` did not persist. Measured, with the
    # diagnostic on the entry line above: on the second visit to the same tab
    # the registry read back `renderedFor=0x0` while `row0.clone` held a live
    # pointer from the first render. So the row mutations survived and the
    # scalar assignment did not -- the rows are a `seq`, whose buffer is shared
    # by every copy, while `renderedFor` is a plain field that a copy owns.
    # Both `gSwPages[i].field = x` and passing `gSwPages[i]` to a `var`
    # parameter were operating on a temporary.
    #
    # The visible symptom was the whole page being cloned again on every tab
    # visit -- two 'aowlspt - host' rows on screen after two visits, and the
    # `renderedFor == tabKey` guard above never able to fire, which is also why
    # its "lost its clones" branch never appeared in the log.
    #
    # This is a nimony/Nim-2 semantic difference, not a logic error, so it is
    # fixed by not depending on the aliasing at all.
    var pg = gSwPages[i]
    discard swRenderPage(tabPtr, parentGo, pg)
    pg.renderedFor = tabKey
    gSwPages[i] = pg
    # THIS CALL HAS SPENT ITS ONE BEGIN. Recorded from the WRITTEN-BACK page,
    # not from the local, so a begin that did not persist does not lock the
    # rest of the registry out.
    if gSwPages[i].begun and not gSwPages[i].complete:
      begunThisCall = true
      inFlight = i
    # ISOLATE WHICH HALF FAILS. `pg` is what we just built; `gSwPages[i]` is
    # what the registry holds one statement later. If they disagree, the
    # element assignment itself is the no-op and no amount of read-modify-write
    # will fix it. If they agree here but the value is gone by the next tab
    # visit, something is resetting the registry between visits instead.
    if gSwPagesFires <= 8:
      okLog "settings pages: write-back check -- local pg.renderedFor=0x" &
            hexOf(pg.renderedFor) & " registry gSwPages[i].renderedFor=0x" &
            hexOf(gSwPages[i].renderedFor) &
            "  local rows=" & $pg.rows.len &
            " registry rows=" & $gSwPages[i].rows.len &
            "  local row0.clone=0x" &
            (if pg.rows.len > 0: hexOf(pg.rows[0].clone) else: "-") &
            " registry row0.clone=0x" &
            (if gSwPages[i].rows.len > 0: hexOf(gSwPages[i].rows[0].clone)
             else: "-")
    i = i + 1
