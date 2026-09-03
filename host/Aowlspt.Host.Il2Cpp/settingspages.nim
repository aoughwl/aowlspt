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

## The marker a not-yet-wired row carries. Deliberately verbose: a settings row
## that silently does nothing is worse than no row, and this is the project's
## existing `implemented = false` convention made visible natively.
const cSwNotDone = "  (not done yet)"

## How many rows one page may render. A cap, not an expectation -- it bounds the
## clone count so a bad schema cannot instantiate hundreds of Unity objects into
## a live screen. Raised from 24 to fit a mod schema's real rows PLUS one
## header row per category (mods/tarkov alone is 22 rows across 8 categories =
## 30) -- still a bound, not a target.
const cSwMaxRows = 48

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
  # (reflection is dead on this build) and it is exactly how `swKlassName` and
  # the Phase 2b reader already decide what a control is.
  let wk = cast[uint64](cReadPtrAt(widget, 0'i32))
  if gSwKlassToggle == 0'u64 or wk != gSwKlassToggle:
    if not gSwSeedRefused:
      gSwSeedRefused = true
      okLog "settings pages: NOT seeding a toggle value -- the cloned row's " &
            "widget klass is 0x" & hexOf(wk) & " and the learned toggle klass " &
            "is 0x" & hexOf(gSwKlassToggle) &
            (if gSwKlassToggle == 0'u64:
               " (never learned: no stock toggle row was found on this tab, " &
               "which a non-English client will also do)"
             else: " (the donor is not a toggle)") &
            ". Calling Toggle::SetIsOnWithoutNotify on it FAULTS, and the " &
            "caught fault used to abort the rest of the page render -- which " &
            "is what made the page clone itself on every tab visit. The row " &
            "is left showing the donor's value; that is cosmetic and safe."
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

proc swRenderPage(tabPtr, parentGo: Il2CppPtr; page: var SwPage): int =
  ## Render one page's rows onto a tab. Returns how many rows were rendered.
  ##
  ## A heading row comes first, then one row per schema row. A stub page renders
  ## its heading and its note and stops -- which is the point of `stub`: the
  ## player sees the page exists and is told plainly that it does nothing yet.
  result = 0
  swCrumb("STAGE: swRenderPage -- swAnyDonor for page '" & page.id & "'")
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
  # The heading, cloned from the same donor so it inherits the row styling. It
  # is a toggle underneath, which is not ideal and IS honest: there is no label
  # widget to clone on a settings tab that we can identify without reflection.
  swCrumb("render the heading row for page '" & page.id & "'")
  discard swCloneRow(donorToggle, parentGo, page.title)
  if page.stub:
    discard swCloneRow(donorToggle, parentGo, page.note & cSwNotDone)
    okLog "settings pages: page '" & page.id & "' is a STUB -- heading and " &
          "note rendered, no rows bound"
    return
  var i = 0
  var skipped = 0
  var lastSkipWhy = ""
  while i < page.rows.len and result < cSwMaxRows:
    swCrumb("STAGE: swRenderPage -- validate row " & $i & " of " &
            $page.rows.len & " page '" & page.id & "'")
    var why = ""
    if not swRowIsSane(page.rows[i], why):
      skipped = skipped + 1
      lastSkipWhy = why
      warn "settings pages: page '" & page.id & "' row " & $i &
           " SKIPPED (not rendered) -- " & why
      i = i + 1
      continue
    var text = page.rows[i].label
    if not page.rows[i].implemented:
      text = text & cSwNotDone
    swCrumb("render row " & $i & " of " & $page.rows.len & " ('" & text & "')")
    let clone = swCloneRow(donorToggle, parentGo, text)
    if clone != nil:
      page.rows[i].clone = cast[uint64](clone)
      if page.rows[i].kind == swkToggle:
        swCrumbP("swSeedToggle for row '" & text & "' clone", clone)
        page.rows[i].seeded = swSeedToggle(clone, page.rows[i].bval)
      elif page.rows[i].kind == swkColor:
        # THE COLOUR WIDGET. Not a clone: there is no colour control on any
        # stock settings tab to clone, so it is BUILT on top of the row's own
        # clone (which supplies the label and the row styling) from nuikit
        # primitives. A build failure is not fatal to the page -- the row stays
        # as a labelled clone, `seeded` stays false, and read-back therefore
        # gives it no vote, exactly like a toggle whose seed refused.
        swCrumbP("cwBuildForRow for row '" & text & "' clone", clone)
        let slot = cwBuildForRow(clone, parentGo, page.rows[i].key,
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
      result = result + 1
      # ONE-SHOT GEOMETRY DUMP. Rows are being cloned and labelled and the user
      # sees nothing, so the next question is WHERE they went -- and that is a
      # question to ask the client, not to reason about. Dump the donor and the
      # first clone side by side; every field the two share is inherited and
      # every field that differs is ours.
      if not gSwGeomDumped:
        gSwGeomDumped = true
        swDumpRowGeometry(donorToggle, clone, parentGo)
    i = i + 1
  # THE FALSIFIABLE NEGATIVE, over the FINISHED PAGE rather than over our own
  # write: "no row whose SCHEMA declared a colour still ended up rendered as a
  # stub or as an unbound text row". Stated as a negative because a negative can
  # fail -- counting the widgets we built and comparing that to itself cannot.
  # THREE OUTCOMES: no declared colour rows at all is INCONCLUSIVE, not a pass.
  var declared = 0
  var stillStub = 0
  var unbound = 0
  var k = 0
  while k < page.rows.len:                 # capped: cSwMaxRows
    if page.rows[k].declaredColor:
      inc declared
      if page.rows[k].kind != swkColor:
        inc stillStub
      elif page.rows[k].cwIdx == 0'i32 or not page.rows[k].seeded:
        inc unbound
    k = k + 1
  if declared == 0:
    okLog "settings pages: page '" & page.id & "' colour check INCONCLUSIVE " &
          "-- this page's schema declared no colour row, so nothing was " &
          "examined. That is not a pass."
  elif stillStub > 0 or unbound > 0:
    warn "settings pages: page '" & page.id & "' colour check FAIL -- of " &
         $declared & " row(s) whose schema declared a colour, " & $stillStub &
         " still render as a plain text/stub row (the value would not parse) " &
         "and " & $unbound & " drew no working widget. THIS IS THE REPORTED " &
         "BUG's SIGNATURE: a colour setting showing its raw value as text."
  else:
    okLog "settings pages: page '" & page.id & "' colour check PASS -- all " &
          $declared & " row(s) whose schema declared a colour render a bound " &
          "colour widget; none is left as a stub or a bare text row."
  okLog "settings pages: page '" & page.id & "' rendered " & $result &
        " row(s) of " & $page.rows.len &
        (if skipped > 0:
           " -- " & $skipped & " row(s) SKIPPED as unsafe (last reason: " &
           lastSkipWhy & ")"
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
       page.rows[i].kind == swkToggle:
      let control = cast[Il2CppPtr](page.rows[i].clone)
      swCrumbP("read back row '" & page.rows[i].key & "' clone", control)
      var ok = false
      let live = swReadToggle(control, ok)
      if ok and live != page.rows[i].bval:
        okLog "settings pages: row '" & page.rows[i].key & "' changed " &
              swBoolText(page.rows[i].bval) & " -> " & swBoolText(live) &
              " in game"
        if page.modGuid.len > 0:
          # A mod page: the file that would change is the mod's, not ours, and
          # it lives across a process boundary -- POST it, and take the value
          # only optimistically (see `modsettingsrender.swModSetDrainPost` for
          # the outcome, which is asserted, not assumed).
          modSetQueueWrite(page.modGuid, page.rows[i].key, swBoolText(live))
          page.rows[i].bval = live
        elif swSetHostFlag(page.rows[i].key, live):
          page.rows[i].bval = live
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
  var i = 0
  while i < gSwPages.len:
    swCrumb("STAGE: swPagesOnTabBuilt -- page[" & $i & "/" & $gSwPages.len &
            "] id='" & gSwPages[i].id & "' rows=" & $gSwPages[i].rows.len)
    # Read back BEFORE deciding whether to re-render, so a value the player
    # changed is captured even on the pass that decides to rebuild the page.
    if gSwPages[i].renderedFor == tabKey:
      swReadBackPage(gSwPages[i])
      # Still rendered into this same tab object; nothing to rebuild. A clone
      # that has been destroyed under us reads unreadable, and that is what
      # forces a re-render.
      var alive = false
      var r = 0
      while r < gSwPages[i].rows.len:
        if gSwPages[i].rows[r].clone != 0'u64 and
           cIsReadable(cast[Il2CppPtr](gSwPages[i].rows[r].clone), 8'i32) != 0'i32:
          alive = true
          break
        r = r + 1
      if alive:
        i = i + 1
        continue
      okLog "settings pages: page '" & gSwPages[i].id & "' lost its clones " &
            "(the tab was rebuilt under it); re-rendering"
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
