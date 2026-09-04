## ===========================================================================
## settingsbind.nim -- THE VALUE BINDING for host-built settings rows.
##
## The rows `postfxrows.nim` instantiates out of the game's own prefabs LOOK
## like settings and, before this file, WERE NOT ONE: moving a slider or
## clicking a toggle changed a pixel and nothing else. This is the half that
## makes a row a setting -- the event, the staging, the persist and the
## fail-able verdict.
##
## WHY NOT THE GAME'S OWN BIND PATH -- MEASURED, NOT ASSUMED
## ---------------------------------------------------------
## Four routes exist and three are closed on this build:
##
##   * `SettingToggle.BindTo(GameSetting<bool>)` @0x16FD0D0 and
##     `SettingFloatSlider.BindTo(GameSetting<float>,...)` @0x16FB810 have real
##     unique RVAs and nothing to pass them: `Bsg.GameSettings.GameSetting`1` is
##     an INSTANTIATED GENERIC whose layout is not reachable offline (all 33,464
##     `Il2CppGenericClass` entries carry a null `cached_class`). Constructing
##     one is a gap, not a step.
##   * `SettingControl::SetChangeAction(Action)` @0x16FAFC0 takes a managed
##     `System.Action`. Producing one needs runtime type/delegate injection,
##     which is PLAUSIBLE and UNPROVEN here. It is called with a real delegate
##     or not at all -- never with NULL.
##   * `SettingDropDown::BindTo` and all three `SettingSelectSlider.BindIndexTo`
##     overloads are GENERIC and have no offline code entry at all. postfxrows
##     already DECLINES to build `preset` and `tonemapper` for exactly that
##     reason and this file does not quietly un-decline them.
##
## The fourth route needs no injection and is the one taken here: the widgets
## the rows are built out of are stock Unity/EFT widgets, and every value
## change in the game funnels through two UNIQUE, byte-verifiable methods.
##
## THE TWO MEASURED EVENT ROUTES
## -----------------------------
##   TOGGLE ROWS.  `UnityEngine.UI.Toggle::Set(bool value, bool sendCallback)`
##                 @0x55BA450, sharedness=UNIQUE (`il2cpp_resolve.py shared`).
##                 NO NEW DETOUR: `nativetabs.nim` already owns the one prefix
##                 there, and a second physical detour would overwrite its
##                 trampoline and silently kill the subtab strip. This file
##                 rides it as a drain, entered from `pfxOnToggleSet`.
##                 Register indices are POSITIONAL: this=0(RCX),
##                 value=1(RDX), sendCallback=2(R8B).
##
##   SLIDER ROWS.  `UnityEngine.UI.Slider::Set(float input, bool sendCallback)`
##                 @0x55B44A0, arity 2, sharedness=UNIQUE, prologue
##                 `48 89 5C 24 08 57 48 83 EC 30 80 3D 86 3C B2 01`
##                 (`il2cpp_resolve.py typemethods/shared/bytes`, 2026-09-03).
##                 A NEW read-only PREFIX -- nothing else in this host patches
##                 it. FOUR register slots (this, input, sendCallback,
##                 MethodInfo*), so it is inside `PostfixMaxSlots`; it is bound
##                 as a PREFIX anyway, which is unconditionally safe for any
##                 arity.
##
##                 THE FLOAT IS IN XMM1, NOT RDX. `input` is argument POSITION
##                 1, and on Win64 the position picks the register FILE. Read
##                 with `cRegsF32(regs, 1)` -- `cRegsFlt` reads the slot as a
##                 double and returns a number unrelated to the argument
##                 (12.5f came back 0.000000), and `cRegsInt(regs, 1)` reads
##                 RDX, which nobody wrote.
##
##                 The row's `UnityEngine.UI.Slider` is reached from the row's
##                 `EFT.UI.NumberSlider` through `_slider` @0x80 -- MEASURED
##                 from `Il2CppMetadataRegistration.fieldOffsets`
##                 (`il2cpp_resolve.py fields EFT.UI.NumberSlider`, String
##                 self-check passing), never guessed.
##
##   DROPDOWN ROWS.  NOT BOUND, and no row is built for one. See above.
##
## THE PERSIST ROUTE
## -----------------
## `modSetQueueWrite(guid, key, jsonValue)` -- the EXACT write the F12 mod
## settings overlay uses (`modsettingsrender.nim`), which POSTs
## `/aowlspt/settings/<guid>` and therefore runs the mod's own
## `onSettingsApplied`. A value stored without that hook changes a file and
## nothing else: the setting appears to work and does not.
##
## Staged first, flushed on SAVE: `EFT.UI.Settings.SettingsScreenController::
## SaveSettings()` @0x1721E20, arity 0, sharedness=UNIQUE, prologue
## `40 53 48 83 EC 70 80 3D FE C5 99 05 00 48 8B D9`. Bound as a PREFIX (2
## slots), read-only, never suppressing.
##
## REVERT, said honestly. The game's settings Revert is
## `SettingsWithProvider`1::RevertToDefault()`, which is GENERIC and has
## **RVA=None** -- there is no address to bind. So this file does NOT bind a
## revert. What it does instead is DISCARD: a staged value that was never
## flushed by a SAVE is dropped when the rows are torn down (`sbdSweep`, called
## from `pfxDestroyAll`). Closing the screen without saving therefore persists
## nothing, which is the behaviour a Revert produces; it is not the same
## mechanism and this comment does not pretend it is.
##
## SEEDING
## -------
## A row is seeded from the CURRENT config value when one is available: the
## `/aowlspt/settings/<guid>` page `modsettingsrender.nim` parsed into
## `gSwPages` carries the mod's live values in exactly the schema's shape.
## When that page is absent -- `modSettingsRender` off, or the fetch has not
## completed -- `sbdSeedF`/`sbdSeedB` return `false` and the caller keeps the
## DECLARED DEFAULT and says so. Three states, never two: seeded-from-config,
## seeded-from-default, refused.
##
## THE VERDICT, and why it can fail
## --------------------------------
## Two checks, both against the FINISHED STATE and neither against our own
## write:
##
##   V1 LIVE.    After a flush, re-read the live control -- `nuSliderValue`
##               (which calls `NumberSlider::CurrentValue`, the game's own
##               getter) or `Toggle.m_IsOn` @0x120 -- and compare against the
##               value that was POSTed. A row that disagrees prints FAIL and
##               NAMES THE ROW.
##   V2 CONFIG.  When a FRESH schema page for the same guid appears in
##               `gSwPages` after a flush, compare the config's value for each
##               flushed key against what was written. A row whose control
##               changed but whose config did not prints FAIL and names it.
##               This is the read-back "through the same accessor" and it is
##               the one that can catch a POST that was accepted and dropped.
##
## Absence of a fresh page is INCONCLUSIVE and is printed as INCONCLUSIVE, not
## folded into PASS.
##
## SAFETY -- the eight rules
## -------------------------
## 1. Every bind goes through `nuFn`, which byte-verifies the 16-byte prologue
##    against the STARTUP SNAPSHOT (never live memory).
## 2. Every pointer hop is `nuOk`/`nuAlive` guarded; a stored control handle is
##    never dereferenced on fewer than both.
## 3. NO GUARD IS OPENED HERE. Both drains run inside the dispatcher's single
##    `aowl_p_p_seh`, and that guard is not re-entrant -- a nested one disarms
##    the outer.
## 4. Every loop is bounded by `SbdMaxRows`.
## 5. Flag-gated `settingsRowsBind`, DEFAULT OFF. Idle cost with the flag off
##    is one boolean compare on the two drains.
## 6. Self-disables after `SbdMaxFaults` faults for the session.
## 7. No per-frame managed allocation: the drains do pointer compares and float
##    stores into Nim statics. The only allocation is on a SAVE press.
## 8. Nothing here writes game memory. The one write is the SEED, and it goes
##    through `nuSliderValue`'s counterpart setter `nuSliderSetValue` -- a call
##    to the game's own `NumberSlider::SetCurrentValue`, not a store. There is
##    no raw cast-store in this file, so `tools/storelint.py` stays clean by
##    construction rather than by exemption.
## ===========================================================================

const
  SbdMaxRows   = 64
  SbdMaxFaults = 2
  ## The graphics mod's guid, verbatim from `mods/graphics/graphics.nim:44`
  ## (`ModGuid = "aowl.graphics"`). `postfxrows.nim` mirrors that mod's schema,
  ## so its rows persist to that mod and no other. It is the guid of ONE
  ## CONSUMER, not a property of this file: the registry is keyed by
  ## (modGuid, key) throughout and V2 below iterates whatever guids are
  ## actually registered.
  SbdPostFxGuid = "aowl.graphics"
  ## `UnityEngine.UI.Toggle.m_IsOn`. Already in `nativeui.nim` as
  ## `NuOffToggleIsOn`; named again here only in the comment, not re-declared.
  ## `EFT.UI.NumberSlider._slider : UnityEngine.UI.Slider` -- MEASURED
  ## 2026-09-03 with `il2cpp_resolve.py fields EFT.UI.NumberSlider`
  ## (System.String._stringLength@0x10 self-check passing).
  SbdOffNumSliderSlider = 0x80'i32
  ## A change smaller than this on a 0..1-ish settings slider is register noise
  ## or a repaint, not an edit. Sliders here declare ranges as wide as -3..3,
  ## so this is relative to the row's own range, not absolute.
  SbdSliderEps = 1.0e-4'f32

type
  SbdKind = enum
    sbdToggle
    sbdSlider
    sbdEnable                  ## a per-MOD enabled switch, not a setting row
    ## A NATIVE DROPDOWN (`EFT.UI.DropDownBox`). It is a row like any other in
    ## everything except HOW ITS EDIT ARRIVES: there is no `Slider::Set` or
    ## `Toggle::Set` drain for a dropdown on this build (the whole
    ## `SettingDropDown` bind family -- `BindTo`, `BindToEnum`,
    ## `UpdateDropDownValue` -- is generic and has NO RVA offline), so the
    ## selection is POLLED off the control itself in `sbdTick`. That is the
    ## honest shape here: it observes the FINISHED STATE of the game's own
    ## widget rather than an event we hoped would arrive.
    sbdDropdown

  SbdRow = object
    guid*: string
    key*: string
    kind*: SbdKind
    ## The pointer the EVENT is matched on. For `sbdToggle` this is the
    ## `UnityEngine.UI.Toggle` the row's `SettingToggle.Toggle` @0xA8 holds;
    ## for `sbdSlider` it is the `UnityEngine.UI.Slider` at
    ## `NumberSlider._slider` @0x80. Never a name, never a sibling index.
    ev*: Il2CppPtr
    ## The widget the VERDICT reads back through the game's own getter. For a
    ## slider row that is the `NumberSlider`, not the Unity Slider, because
    ## `NumberSlider::CurrentValue` is the value the row displays.
    read*: Il2CppPtr
    lo*, hi*: float32
    ## What the row was seeded with, and whether that came from the config.
    seedB*: bool
    seedF*: float32
    fromConfig*: bool
    ## The player's edit, staged and not yet persisted.
    stagedB*: bool
    stagedF*: float32
    staged*: bool
    ## What was actually POSTed, for both verdicts.
    flushedB*: bool
    flushedF*: float32
    flushed*: bool

var gSbdInit = false
var gSbdOn = false                 ## `settingsRowsBind`, DEFAULT OFF
var gSbdOff = false                ## self-disabled
var gSbdFaults = 0
var gSbdRows: seq[SbdRow] = @[]
## True only while THIS file is seeding a control, so our own
## `NumberSlider::SetCurrentValue` -- which reaches `Slider::Set` with a
## callback -- cannot be mistaken for the player moving the slider. The toggle
## side needs no equivalent: this file never writes a toggle, and the drain
## already ignores `sendCallback=false`.
var gSbdApplying = false
## THE EVENT CENSUS. Three states have to be distinguishable and, before this,
## none of them were: (a) the drain never reached us at all, (b) it reached us
## and matched no row, (c) it matched. A silent (a) and a silent (b) look
## identical from the log, and that is exactly the pair that cost the live
## session at 18:36 -- a toggle whose `m_IsOn` provably went 1 -> 0 produced no
## line of any kind.
var gSbdTogSeen = 0        ## Toggle::Set events that reached `sbdOnToggleSet`
var gSbdTogMatched = 0     ## ...of those, how many matched a registered row
var gSbdSlidSeen = 0
var gSbdSlidMatched = 0
var gSbdSaveCount = 0
## Dropdown selections observed to MOVE by the poll. A dropdown row that never
## moves and a poll that never runs are different bugs and must not print the
## same line.
var gSbdDropMoved = 0

## WHICH MODS ACTUALLY HAD A VALUE CHANGE AT THE LAST SAVE.
##
## A feature that must react to "the player changed one of MY rows and pressed
## SAVE" cannot ask the SAVE prefix, which fires on every press including the
## ones that changed nothing, and it must not ask its own record of what it
## wrote. `sbdFlush` is the only place that knows a row was STAGED (an edit
## the game's own Slider::Set / Toggle::Set event delivered) and is now
## written, so the guid is recorded there and nowhere else.
##
## Capped, and CONSUMED by the reader: a guid left in this list would make the
## next screen visit look like a fresh change.
const SbdMaxSavedGuids = 8
var gSbdSavedGuids: seq[string] = @[]

proc sbdNoteSaved(guid: string) =
  if guid.len == 0 or gSbdSavedGuids.len >= SbdMaxSavedGuids: return
  var i = 0
  while i < gSbdSavedGuids.len and i < SbdMaxSavedGuids:
    if gSbdSavedGuids[i] == guid: return
    i = i + 1
  gSbdSavedGuids.add guid

proc sbdTakeSaved*(guid: string): bool =
  ## True EXACTLY ONCE per SAVE that carried a changed row of `guid`, and it
  ## removes the entry, so a second caller in the same frame gets false. The
  ## caller owns the consequence of consuming it.
  result = false
  var i = 0
  while i < gSbdSavedGuids.len and i < SbdMaxSavedGuids:
    if gSbdSavedGuids[i] == guid:
      gSbdSavedGuids.delete(i)
      return true
    i = i + 1
## Pointers already probed for a BIND MISS report, so the name lookup is done
## at most once per distinct toggle and the work on the game's click path stays
## bounded. Capped hard: this is on the path of EVERY toggle in the game.
var gSbdMissProbed: seq[Il2CppPtr] = @[]
var gSbdMissSaid = 0
const SbdMaxMissSaid = 4
const SbdMaxMissProbed = 12
## `gSbdSlotSlider` / `gSbdSlotSave` are declared in `aowlhost.nim` beside
## `gNtToggleSlot`, above `patchFired`, because that is where the dispatcher
## can see them. They are NOT re-declared here: a second `var` of the same name
## in a textually-included file is a different variable, and the one the
## dispatcher compares against would stay -1 forever.
var gSbdBound = false
var gSbdSaidBind = false
## Set by the SAVE prefix, drained by `sbdVerdictTick` on the Unity main thread.
## The prefix itself does no allocation and no POST: it is inside the game's own
## save call and the write is queued work.
var gSbdSaveSeen = false
## THE WRITE QUEUE, and the measured reason it has to exist.
##
## `overlayPostStart` is a SINGLE SLOT: "arming a second one before the first is
## taken REPLACES it" (`host/Aowlspt.Overlay/aowloverlay.nim`). A flush that
## looped over the staged rows calling `modSetQueueWrite` for each would
## therefore send the LAST row and silently drop every other one -- and it would
## look like it worked, because one write really did go out. So the flush fills
## this queue and `sbdPump` releases exactly one write per tick, and only while
## `overlayPostPending()` is clear.
var gSbdQGuid: seq[string] = @[]
var gSbdQKey: seq[string] = @[]
var gSbdQVal: seq[string] = @[]
var gSbdQAt = 0
const SbdMaxQueue = SbdMaxRows
## Verdict bookkeeping. `gSbdWantConfigCheck` arms V2; it is disarmed by the
## first page that is FRESH ENOUGH to answer, or reported INCONCLUSIVE when the
## screen goes away without one.
var gSbdWantConfigCheck = false
var gSbdPendingConfigArm = false
var gSbdConfigWaitFrames = 0
const SbdConfigWaitMax = 900       ## ~15s at 60fps before calling it INCONCLUSIVE

proc sbdFault(what: string) =
  gSbdFaults = gSbdFaults + 1
  warn "settings bind: " & what & " (fault " & $gSbdFaults & "/" &
       $SbdMaxFaults & ")"
  if gSbdFaults >= SbdMaxFaults:
    gSbdOff = true
    warn "settings bind: SELF-DISABLED for this session after " &
         $SbdMaxFaults & " fault(s). No row is bound, no value is staged and " &
         "nothing is written. Rows already on screen keep whatever value they " &
         "are showing -- they are no longer a setting, and the banner's " &
         "'not bound' wording is once again the truthful one."

proc sbdInitFlags() =
  ## Idempotent. Called from BOTH the bind site and the tick, because the bind
  ## runs first (it must -- it is in the region where the prologue snapshot is
  ## primed) and a tick-only init would leave `sbdBind` refusing a feature the
  ## player had turned on.
  if gSbdInit: return
  gSbdInit = true
  gSbdOn = readBoolKeyDef("settingsRowsBind", false)
  if gSbdOn:
    okLog "settings bind: ON (settingsRowsBind). Toggle rows ride the " &
          "existing Toggle::Set @0x55BA450 prefix; slider rows use a new " &
          "read-only prefix on UnityEngine.UI.Slider::Set @0x55B44A0 " &
          "(UNIQUE, prologue-verified). Edits are STAGED and written only " &
          "on SettingsScreenController::SaveSettings @0x1721E20."

proc sbdReady(): bool =
  gSbdInit and gSbdOn and not gSbdOff

# ---------------------------------------------------------------------------
# SEEDING -- the CURRENT config value, or an honest refusal.
# ---------------------------------------------------------------------------

proc sbdPageFor(guid: string; idx: var int): bool =
  ## The parsed `/aowlspt/settings/<guid>` page, if `modsettingsrender.nim` has
  ## fetched one. `gSwPages` is a Nim seq owned by the Unity main thread and
  ## every caller here is on that thread.
  result = false
  idx = -1
  if guid.len == 0: return
  var i = 0
  while i < gSwPages.len and i < 64:
    if gSwPages[i].modGuid == guid:
      idx = i
      return true
    i = i + 1

## HOW MANY ROWS WERE SEEDED FROM WHICH SOURCE. Three states, and the boot
## line used to flatten two of them: "0 of 5 show the player's CONFIG value"
## was true and read as "the config was not applied", when in fact the SCHEMA
## PAGE had simply not been fetched yet and the file on disk had never been
## asked.
var gSbdSeedPage = 0
var gSbdSeedDisk = 0

proc sbdSeedSource*(): (int, int) =
  ## (from the fetched schema page, from the deployed config.json). The DLSS
  ## verdict prints both, because "the config was not applied" and "the schema
  ## page had not been fetched yet" used to print the same line.
  (gSbdSeedPage, gSbdSeedDisk)

proc sbdModIndex(guid: string): int =
  ## The loaded-mod index for a guid, or -1. Capped by `modCount()`, which is
  ## the loader's own count.
  result = -1
  if guid.len == 0: return
  let n = modhost.modCount()
  var i = 0
  while i < n and i < 256:
    if modhost.modGuidOf(i) == guid: return i
    i = i + 1

proc sbdDiskValue(guid, key: string; outv: var string): bool =
  ## The value of `key` in the DEPLOYED `config.json` of mod `guid`, read
  ## through `modhost.configRead` -- the same single reader the backend and the
  ## simulator use, and the same one `aowlspt_nim_config_get` answers from.
  ##
  ## WHY THIS EXISTS. The seed used to come only from the parsed
  ## `/aowlspt/settings/<guid>` page, which `modsettingsrender.nim` fetches
  ## asynchronously. Opening the Graphics tab before that fetch lands built
  ## every row on its DECLARED DEFAULT -- MEASURED live on 2026-09-04, "0 of 5
  ## show the player's CONFIG value" -- so a player who had saved a setting saw
  ## the default and, if they then pressed SAVE, would have written it back.
  ## The file on disk is authoritative, is present before the first frame, and
  ## needed no fetch at all.
  ##
  ## It is the FALLBACK and not the primary: the page reflects writes this
  ## session has already made and the file may not yet, so a stale disk read
  ## must never override a fresher page.
  result = false
  outv = ""
  let idx = sbdModIndex(guid)
  if idx < 0: return
  var text = ""
  var cfgErr = ""
  if modhost.configRead(idx, text, cfgErr) != StatusOk: return
  if text.len == 0: return
  var v = ""
  if not pathGet(text, key, v): return
  outv = v
  true

proc sbdConfigF(guid, key: string; outv: var float32): bool =
  ## The mod's CURRENT value for a float key. False means "could not ask" --
  ## never 0.0, which is a legal value for most of these settings and would
  ## make every check unable to fail.
  ##
  ## The fetched schema page FIRST, the deployed config.json SECOND. Both are
  ## counted, because "seeded from the page" and "seeded from disk" are
  ## different facts and the verdict says which.
  result = false
  var p = -1
  if not sbdPageFor(guid, p):
    var raw = ""
    if sbdDiskValue(guid, key, raw):
      # `duParseNum`, not `parseFloat`: the latter is `.raises` in nimony and a
      # config value that is not a number must be a SKIP (keep the declared
      # default) rather than an exception -- see its own comment in debugui.nim.
      var numOk = false
      let v = duParseNum(strip(raw), numOk)
      if not numOk: return false
      outv = float32(v)
      gSbdSeedDisk = gSbdSeedDisk + 1
      return true
    return
  var r = 0
  while r < gSwPages[p].rows.len and r < 256:
    if gSwPages[p].rows[r].key == key and gSwPages[p].rows[r].kind == swkSlider:
      outv = float32(gSwPages[p].rows[r].fval)
      gSbdSeedPage = gSbdSeedPage + 1
      return true
    r = r + 1
  # The page exists but has no row for this key -- fall through to the file
  # rather than report "could not ask". A schema that has not caught up with a
  # config key is exactly the case that would otherwise show a default.
  var raw2 = ""
  if sbdDiskValue(guid, key, raw2):
    var numOk2 = false
    let v2 = duParseNum(strip(raw2), numOk2)
    if not numOk2: return false
    outv = float32(v2)
    gSbdSeedDisk = gSbdSeedDisk + 1
    return true

proc sbdDiskBool(guid, key: string; outv: var bool): bool =
  ## `true`/`false` out of the deployed config.json. Anything else is REFUSED
  ## rather than coerced -- a config holding `"yes"` is a broken config, not a
  ## true one.
  result = false
  var raw = ""
  if not sbdDiskValue(guid, key, raw): return
  let t = strip(raw)
  if t == "true": outv = true
  elif t == "false": outv = false
  else: return
  gSbdSeedDisk = gSbdSeedDisk + 1
  true

proc sbdConfigB(guid, key: string; outv: var bool): bool =
  ## The page first, the deployed config.json second -- see `sbdConfigF`.
  result = false
  var p = -1
  if not sbdPageFor(guid, p):
    return sbdDiskBool(guid, key, outv)
  var r = 0
  while r < gSwPages[p].rows.len and r < 256:
    if gSwPages[p].rows[r].key == key and gSwPages[p].rows[r].kind == swkToggle:
      outv = gSwPages[p].rows[r].bval
      gSbdSeedPage = gSbdSeedPage + 1
      return true
    r = r + 1
  return sbdDiskBool(guid, key, outv)

# ---------------------------------------------------------------------------
# REGISTRATION. Called by the builder as each row is made, with the pointers
# the builder ALREADY HOLDS -- never re-found by name or by position later.
# ---------------------------------------------------------------------------

proc sbdRegisterSlider*(guid, key: string; numSlider: Il2CppPtr;
                        lo, hi, declaredDefault: float32): bool =
  ## Register a float row and SEED it. Returns true when the seed came from the
  ## config; false means the row keeps `declaredDefault` (and the caller must
  ## say so -- printing a default and letting it read as "your setting" is a
  ## confident wrong answer).
  result = false
  if not sbdReady(): return
  if gSbdRows.len >= SbdMaxRows:
    sbdFault("the row table is full at " & $SbdMaxRows & " row(s); '" & key &
             "' is NOT bound and will change nothing when moved")
    return
  if not nuOk(numSlider, SbdOffNumSliderSlider + 8'i32) or
     not nuAlive(numSlider):
    sbdFault("'" & key & "' has no readable NumberSlider, so its Unity Slider " &
             "cannot be reached and no event can be matched to it. NOT bound")
    return
  let ui = cNuGetRef(numSlider, SbdOffNumSliderSlider)
  if not nuOk(ui, 0x10'i32) or not nuAlive(ui):
    sbdFault("'" & key & "': NumberSlider._slider @0x" &
             hexOf(uint64(SbdOffNumSliderSlider)) & " read " &
             (if ui == nil: "null" else: "0x" & hexOf(cast[uint64](ui))) &
             ", which is not a live UnityEngine.UI.Slider. NOT bound -- a row " &
             "matched on a bad pointer would answer to somebody else's slider")
    return
  var v = declaredDefault
  var fromCfg = false
  var cfg = 0.0'f32
  if sbdConfigF(guid, key, cfg):
    # CLAMP TO THE ROW'S DECLARED RANGE. A config value outside it is a real
    # thing (a hand-edited file, a schema that moved), and seeding a slider
    # outside its own range shows a handle pinned at an end while the number
    # says something else.
    if cfg < lo: cfg = lo
    if cfg > hi: cfg = hi
    v = cfg
    fromCfg = true
  gSbdApplying = true
  let wrote = nuSliderSetValue(numSlider, v)
  gSbdApplying = false
  if not wrote:
    sbdFault("'" & key & "' could not be seeded through " &
             "NumberSlider::SetCurrentValue, so the number on screen is the " &
             "PREFAB's and not this setting's. NOT bound")
    return
  gSbdRows.add SbdRow(guid: guid, key: key, kind: sbdSlider, ev: ui,
                      read: numSlider, lo: lo, hi: hi,
                      seedB: false, seedF: v, fromConfig: fromCfg,
                      stagedB: false, stagedF: v, staged: false,
                      flushedB: false, flushedF: v, flushed: false)
  fromCfg

proc sbdRegisterToggle*(guid, key: string; ctrl: Il2CppPtr;
                        declaredDefault: bool): bool =
  ## Register a bool row. `ctrl` is the `SettingToggle` the builder got back
  ## from `Instantiate` -- the toggle is read from it through
  ## `SettingToggle.Toggle` @0xA8, the same hop `pfxOwnToggle` already uses.
  ##
  ## THE ROW IS NOT SEEDED BY WRITING THE TOGGLE. `Toggle::Set` with a callback
  ## is a real press and re-enters the drain; `SetIsOnWithoutNotify` would need
  ## a second call path and, more importantly, the prefab instance already
  ## comes up in a known state. What is recorded instead is the state the
  ## control is ACTUALLY IN once built, so the first genuine press is measured
  ## against what the player saw rather than against what we intended.
  result = false
  if not sbdReady(): return
  if gSbdRows.len >= SbdMaxRows:
    sbdFault("the row table is full at " & $SbdMaxRows & " row(s); '" & key &
             "' is NOT bound and will change nothing when clicked")
    return
  if not nuOk(ctrl, NuOffSettingToggleTog + 8'i32) or not nuAlive(ctrl):
    sbdFault("'" & key & "' has no readable SettingToggle, so no toggle " &
             "pointer can be taken. NOT bound")
    return
  let tog = cNuGetRef(ctrl, NuOffSettingToggleTog)
  if not nuOk(tog, NuOffToggleIsOn + 4'i32) or not nuAlive(tog):
    sbdFault("'" & key & "': SettingToggle.Toggle @0x" &
             hexOf(uint64(NuOffSettingToggleTog)) & " is not a live " &
             "UnityEngine.UI.Toggle. NOT bound")
    return
  var v = declaredDefault
  var fromCfg = false
  var cfg = false
  if sbdConfigB(guid, key, cfg):
    v = cfg
    fromCfg = true
  gSbdRows.add SbdRow(guid: guid, key: key, kind: sbdToggle, ev: tog,
                      read: tog, lo: 0.0'f32, hi: 0.0'f32,
                      seedB: v, seedF: 0.0'f32, fromConfig: fromCfg,
                      stagedB: v, stagedF: 0.0'f32, staged: false,
                      flushedB: v, flushedF: 0.0'f32, flushed: false)
  fromCfg

proc sbdRegisterDropdown*(guid, key: string; ddb: Il2CppPtr;
                          nChoices: int32; declaredDefault: int32): bool =
  ## Register a NATIVE DROPDOWN row and SEED it. `ddb` is the
  ## `EFT.UI.DropDownBox` the builder already holds (through
  ## `SettingDropDown.DropDown@0xA8`) -- never re-found by name or by index.
  ##
  ## The config value is ONE-BASED, because that is what `mods/dlss`'s schema
  ## and the F12 overlay both show ("1 = 310.5.3, 2 = 310.7.0, ..."), while the
  ## control is ZERO-BASED. The conversion happens HERE, in the only two places
  ## that cross the boundary -- the seed and the flush -- so the three surfaces
  ## cannot drift apart the way they would if each caller did its own.
  ##
  ## Returns true when the seed came from the config; false means the row shows
  ## `declaredDefault` and the caller must say so.
  result = false
  if not sbdReady(): return
  if gSbdRows.len >= SbdMaxRows:
    sbdFault("the row table is full at " & $SbdMaxRows & " row(s); '" & key &
             "' is NOT bound and will change nothing when selected")
    return
  if nChoices <= 0'i32 or nChoices > 16'i32:
    sbdFault("'" & key & "' declares " & $nChoices & " choice(s), which is " &
             "outside 1..16. NOT bound")
    return
  # The receiver must answer the GAME'S OWN getter before anything is written
  # to it: a pointer that reads plausibly but is not a dropdown would take the
  # seed and never show it.
  let (readable, _) = nuDropDownIndex(ddb)
  if not readable:
    sbdFault("'" & key & "': the DropDownBox did not answer get_CurrentIndex " &
             "@0x698550, so it is not a live dropdown this row could be " &
             "matched to. NOT bound")
    return
  var one = declaredDefault
  var fromCfg = false
  var cfg = 0.0'f32
  if sbdConfigF(guid, key, cfg):
    var v = int32(cfg + 0.5'f32)
    # CLAMP TO THE DECLARED CHOICE COUNT. A hand-edited config, or a schema
    # that moved, must not select an index the control does not have.
    if v < 1'i32: v = 1'i32
    if v > nChoices: v = nChoices
    one = v
    fromCfg = true
  if one < 1'i32: one = 1'i32
  if one > nChoices: one = nChoices
  gSbdApplying = true
  let wrote = nuDropDownSetIndex(ddb, one - 1'i32)
  gSbdApplying = false
  if not wrote:
    sbdFault("'" & key & "' could not be seeded through set_CurrentIndex " &
             "@0x698560, so the selection on screen is whatever the cloned " &
             "prefab came up with and not this setting's. NOT bound")
    return
  # READ IT BACK THROUGH THE OTHER FUNCTION. `set_CurrentIndex` is a bare
  # store; comparing our own record against itself would be a check that
  # cannot fail.
  let (ok2, got) = nuDropDownIndex(ddb)
  if not ok2 or got != one - 1'i32:
    sbdFault("'" & key & "' was seeded to index " & $(one - 1'i32) &
             " and get_CurrentIndex reads " &
             (if ok2: $got else: "NOTHING (unreadable)") &
             ". The control and this registry disagree, so the row is NOT " &
             "bound rather than bound to a value the player is not seeing")
    return
  gSbdRows.add SbdRow(guid: guid, key: key, kind: sbdDropdown, ev: ddb,
                      read: ddb, lo: 1.0'f32, hi: float32(nChoices),
                      seedB: false, seedF: float32(one), fromConfig: fromCfg,
                      stagedB: false, stagedF: float32(one), staged: false,
                      flushedB: false, flushedF: float32(one), flushed: false)
  fromCfg

proc sbdPollDropdowns() =
  ## THE DROPDOWN "EVENT". Called once per tick, and it is the only place a
  ## dropdown edit can be noticed, because there is no `DropDownBox` drain to
  ## ride and binding a second detour to make one would overwrite somebody
  ## else's trampoline.
  ##
  ## Cost is one guarded 4-byte read per registered dropdown row per frame --
  ## no allocation, and no log line unless the selection actually MOVED.
  ## `gSbdApplying` keeps our own seed from reading as a player edit.
  if gSbdApplying: return
  var i = 0
  while i < gSbdRows.len and i < SbdMaxRows:
    if gSbdRows[i].kind == sbdDropdown:
      let (ok, zero) = nuDropDownIndex(gSbdRows[i].read)
      if ok:
        let one = float32(zero + 1'i32)
        if one >= gSbdRows[i].lo and one <= gSbdRows[i].hi:
          let was = (if gSbdRows[i].staged: gSbdRows[i].stagedF
                     else: gSbdRows[i].seedF)
          if one != was:
            gSbdRows[i].stagedF = one
            gSbdRows[i].staged = true
            gSbdDropMoved = gSbdDropMoved + 1
            okLog "settings bind: STAGED '" & gSbdRows[i].key & "' = " &
                  $int(one) & " (the dropdown's own get_CurrentIndex moved " &
                  "from " & $int(was) & " to " & $int(one) & "). Not written " &
                  "yet -- it goes out on the next SaveSettings."
    i = i + 1

proc sbdRegisterEnable*(guid: string; ctrl: Il2CppPtr;
                        currentlyEnabled: bool): bool =
  ## A PER-MOD ENABLED SWITCH, for the native MODS tab. Same event route as any
  ## other toggle row -- it is a stock `SettingToggle` and its edge arrives on
  ## the same `Toggle::Set` drain -- but a DIFFERENT write route, which is why
  ## it is a distinct kind rather than a toggle row with a magic key.
  ##
  ## Registering one today gives a switch that STAGES and, on SAVE, refuses
  ## LOUDLY by name (see `sbdFlush`). That is deliberate: the mod-enable write
  ## is `GET /aowlspt/mods/enable|disable/<guid>` and the overlay bridge has no
  ## one-shot GET. A switch that silently did nothing is the defect this
  ## repository produces most often; a switch that says what it could not do is
  ## a to-do with a name on it.
  result = false
  if not sbdReady(): return
  if gSbdRows.len >= SbdMaxRows:
    sbdFault("the row table is full at " & $SbdMaxRows & " row(s); the " &
             "enabled switch for '" & guid & "' is NOT bound")
    return
  if not nuOk(ctrl, NuOffSettingToggleTog + 8'i32) or not nuAlive(ctrl):
    sbdFault("the enabled switch for '" & guid & "' has no readable " &
             "SettingToggle. NOT bound")
    return
  let tog = cNuGetRef(ctrl, NuOffSettingToggleTog)
  if not nuOk(tog, NuOffToggleIsOn + 4'i32) or not nuAlive(tog):
    sbdFault("the enabled switch for '" & guid & "': SettingToggle.Toggle " &
             "@0x" & hexOf(uint64(NuOffSettingToggleTog)) & " is not a live " &
             "UnityEngine.UI.Toggle. NOT bound")
    return
  gSbdRows.add SbdRow(guid: guid, key: "__enabled", kind: sbdEnable, ev: tog,
                      read: tog, lo: 0.0'f32, hi: 0.0'f32,
                      seedB: currentlyEnabled, seedF: 0.0'f32,
                      fromConfig: true,
                      stagedB: currentlyEnabled, stagedF: 0.0'f32,
                      staged: false, flushedB: currentlyEnabled,
                      flushedF: 0.0'f32, flushed: false)
  true

proc sbdSweep*() =
  ## Tear-down. THE DISCARD IS THE POINT: a staged value that no SAVE flushed
  ## is dropped here and never written. That is what closing the screen without
  ## saving must do, and it is what this file has instead of a Revert bind (see
  ## the header -- `RevertToDefault` is generic and has RVA=None).
  var dropped = 0
  var i = 0
  while i < gSbdRows.len and i < SbdMaxRows:
    if gSbdRows[i].staged and not gSbdRows[i].flushed:
      dropped = dropped + 1
    i = i + 1
  if dropped > 0:
    okLog "settings bind: DISCARDED " & $dropped & " edit(s) that were never " &
          "saved -- the rows were torn down without a SaveSettings, so " &
          "nothing was written. This is the revert path; the game's own " &
          "RevertToDefault is generic and has no address to bind."
  gSbdRows = @[]
  gSbdSaveSeen = false
  gSbdWantConfigCheck = false
  gSbdPendingConfigArm = false
  gSbdQGuid = @[]
  gSbdQKey = @[]
  gSbdQVal = @[]
  gSbdQAt = 0

# ---------------------------------------------------------------------------
# THE EVENTS
# ---------------------------------------------------------------------------

proc sbdStageF(i: int; v: float32) =
  let span = (if gSbdRows[i].hi > gSbdRows[i].lo:
                gSbdRows[i].hi - gSbdRows[i].lo else: 1.0'f32)
  let was = (if gSbdRows[i].staged: gSbdRows[i].stagedF else: gSbdRows[i].seedF)
  let d = (if v > was: v - was else: was - v)
  if d < SbdSliderEps * span:
    return
  gSbdRows[i].stagedF = v
  gSbdRows[i].staged = true

proc sbdOnToggleSet*(tog: Il2CppPtr; turnedOn: bool) =
  ## RIDES the `UnityEngine.UI.Toggle::Set` prefix `nativetabs.nim` owns; it
  ## installs NOTHING. Entered from `pfxOnToggleSet`, inside that body's single
  ## `aowl_p_p_seh`, and opens no guard of its own.
  ##
  ## Cost for every foreign toggle in the game: one boolean and at most
  ## `SbdMaxRows` pointer compares, no dereference, no log.
  if not sbdReady() or tog == nil: return
  gSbdTogSeen = gSbdTogSeen + 1
  var i = 0
  while i < gSbdRows.len and i < SbdMaxRows:
    if (gSbdRows[i].kind == sbdToggle or gSbdRows[i].kind == sbdEnable) and
       gSbdRows[i].ev == tog:
      gSbdRows[i].stagedB = turnedOn
      gSbdRows[i].staged = true
      gSbdTogMatched = gSbdTogMatched + 1
      okLog "settings bind: STAGED '" & gSbdRows[i].key & "' = " &
            swBoolText(turnedOn) & " (Toggle::Set on the registered pointer " &
            "0x" & hexOf(cast[uint64](tog)) & "). Not written yet -- it goes " &
            "out on the next SaveSettings."
      return
    i = i + 1
  # A MISS. Every toggle in the game funnels through here, so a miss is the
  # NORMAL case and must not log -- except for a toggle that is demonstrably
  # ONE OF OURS, which is the defect this exists to make impossible to miss.
  #
  # The name lookup is what costs, so it is done at most once per distinct
  # pointer (`gSbdMissProbed`, capped) and only while the registry is
  # non-empty. With no rows registered there is nothing to have missed; that
  # case is reported by the SAVE line's registry count instead.
  if gSbdRows.len == 0: return
  if gSbdMissSaid >= SbdMaxMissSaid: return
  if gSbdMissProbed.len >= SbdMaxMissProbed: return
  var q = 0
  while q < gSbdMissProbed.len:
    if gSbdMissProbed[q] == tog: return
    q = q + 1
  gSbdMissProbed.add tog
  let go = nuGameObjectOf(tog)
  if go == nil: return
  let nm = iObjName(go)
  if nm.len < 11 or nm[0 .. 10] != "aowlspt-pfx":
    return                            # a foreign toggle; silence is correct
  gSbdMissSaid = gSbdMissSaid + 1
  warn "settings bind: BIND MISS: Toggle::Set on '" & nm & "' (toggle 0x" &
       hexOf(cast[uint64](tog)) & ") matched NO registered row -- the " &
       "registry holds " & $gSbdRows.len & " row(s). That GameObject name is " &
       "ours, so this row was built and NOT registered, or it was registered " &
       "with a DIFFERENT pointer than the one the game raises the event on. " &
       "Registration takes SettingToggle.Toggle@0xa8 (an UpdatableToggle, " &
       "which derives from UnityEngine.UI.Toggle) off the SettingControl that " &
       "Instantiate returned. The row is on screen and changes nothing."

proc sbdSliderSetFired(regs: Il2CppPtr) =
  ## `UnityEngine.UI.Slider::Set(this, float input, bool sendCallback)`.
  ## POSITIONAL register indices: this=0 (RCX), input=1 (**XMM1**),
  ## sendCallback=2 (R8B). Reading `input` out of RDX is the silent version of
  ## this bug -- it compares register residue against a slider value and simply
  ## never matches, which no log would show.
  if not sbdReady(): return
  if gSbdApplying: return
  let selfPtr = cast[Il2CppPtr](cRegsInt(regs, 0'i32))
  if selfPtr == nil: return
  # `SetValueWithoutNotify` and the game's own restore pass sendCallback=false.
  # Those are not edits.
  if (cast[uint64](cRegsInt(regs, 2'i32)) and 0xFF'u64) == 0'u64: return
  gSbdSlidSeen = gSbdSlidSeen + 1
  var i = 0
  while i < gSbdRows.len and i < SbdMaxRows:
    if gSbdRows[i].kind == sbdSlider and gSbdRows[i].ev == selfPtr:
      gSbdSlidMatched = gSbdSlidMatched + 1
      sbdStageF(i, float32(cRegsF32(regs, 1'i32)))
      return
    i = i + 1

proc sbdStagedCount(): int =
  result = 0
  var i = 0
  while i < gSbdRows.len and i < SbdMaxRows:
    if gSbdRows[i].staged: result = result + 1
    i = i + 1

proc sbdCensus(): string =
  ## The one string that separates the three failure states from each other.
  "registry=" & $gSbdRows.len & " staged=" & $sbdStagedCount() &
  " toggleEvents=" & $gSbdTogSeen & "/matched " & $gSbdTogMatched &
  " sliderEvents=" & $gSbdSlidSeen & "/matched " & $gSbdSlidMatched &
  " dropdownMoves=" & $gSbdDropMoved

proc sbdSaveFired() =
  ## `SettingsScreenController::SaveSettings()` PREFIX.
  ##
  ## IT LOGS, ON EVERY PRESS, and that is a deliberate reversal. The previous
  ## version set a flag silently and left the reporting to the tick -- so when
  ## the second SAVE of the live 18:36 session produced NO line at all, nothing
  ## could distinguish "the prefix never fired" from "the prefix fired and the
  ## tick never drained it". Those have completely different fixes. One line
  ## here answers it outright.
  ##
  ## Rule 7 (no per-frame managed allocation) is not weakened: a SAVE press is
  ## a human action, not a frame. This is the only allocating line on the
  ## game's own save path and it is one per press.
  if not sbdReady(): return
  gSbdSaveCount = gSbdSaveCount + 1
  gSbdSaveSeen = true
  okLog "settings bind: SAVE #" & $gSbdSaveCount & " seen on the " &
        "SettingsScreenController::SaveSettings prefix -- " & sbdCensus() &
        ". The writes and the verdicts run on the next tick; if no further " &
        "'settings bind' line follows this one, the PREFIX fired and the TICK " &
        "did not drain it (sbdTick rides pfxOnPanelUp), which is a different " &
        "fault from the prefix not firing."

# ---------------------------------------------------------------------------
# THE FLUSH AND THE TWO VERDICTS
# ---------------------------------------------------------------------------

proc sbdF(v: float32): string =
  ## FOUR decimals, not `nuF`'s one. `nuF` is for a log line about geometry;
  ## this string is what gets POSTed into the mod's config, and rounding
  ## `exposure = 0.42` to `0.4` on the way out would make the config disagree
  ## with the screen -- which is precisely what V1/V2 exist to catch, so it
  ## would be caught, loudly, as somebody else's bug.
  formatFloat(float64(v), ffDecimal, 4)

proc sbdReadLiveF(i: int; outv: var float32): bool =
  ## Through the GAME'S OWN getter (`NumberSlider::CurrentValue`), not our
  ## record of what we last wrote. A comparison against our own write cannot
  ## fail, and that is the defect class this whole file is judged by.
  result = false
  let p = gSbdRows[i].read
  if not nuOk(p, 0x10'i32) or not nuAlive(p): return
  let (ok, v) = nuSliderValue(p)
  if not ok: return
  outv = v
  true

proc sbdReadLiveB(i: int; outv: var bool): bool =
  result = false
  let p = gSbdRows[i].read
  if not nuAlive(p): return
  let (ok, v) = nuToggleIsOn(p)     # `m_IsOn` @0x120, itself nuOk-guarded
  if not ok: return
  outv = v
  true

proc sbdEnqueue(guid, key, val: string) =
  ## One row's write, held until the single POST slot is free. Capped: a queue
  ## that could grow without bound on a stuck backend is an allocation loop on
  ## the Unity main thread.
  if gSbdQGuid.len >= SbdMaxQueue:
    sbdFault("the write queue is full at " & $SbdMaxQueue & " entry(ies); the " &
             "edit to '" & key & "' was DROPPED and is not in the config. The " &
             "backend is not taking writes")
    return
  gSbdQGuid.add guid
  gSbdQKey.add key
  gSbdQVal.add val

proc sbdPump(): bool =
  ## Release at most ONE queued write per tick, and only when the shared POST
  ## slot is clear. Returns true when the queue is empty -- which is the
  ## precondition for arming V2, because a config read taken while writes are
  ## still in flight answers a question nobody asked.
  if gSbdQAt >= gSbdQGuid.len:
    if gSbdQGuid.len > 0:
      gSbdQGuid = @[]
      gSbdQKey = @[]
      gSbdQVal = @[]
      gSbdQAt = 0
    return true
  if overlayPostPending():
    return false
  modSetQueueWrite(gSbdQGuid[gSbdQAt], gSbdQKey[gSbdQAt], gSbdQVal[gSbdQAt])
  gSbdQAt = gSbdQAt + 1
  false

## ---------------------------------------------------------------------------
## V3 ENABLE -- the read-back for a per-mod ENABLED switch.
##
## V1 (the live control) and V2 (the mod's own settings page) cannot answer
## this one: an enable does not go to `/aowlspt/settings/<guid>` and the
## on-screen toggle is the thing we just wrote, so comparing against it is a
## check that cannot fail. The only accessor that can falsify it is the MOD
## MANAGER'S OWN ANSWER, which arrives in the overlay's panel poll -- the same
## table the F12 rows are drawn from.
##
## Two things make it fail-able rather than decorative:
##   * it waits out `overlayModPending`, so it is not reading the optimistic
##     value the toggle wrote into the table on the way out;
##   * it records what the manager said BEFORE the ask, and a run where that
##     already equalled the wanted state is reported INCONCLUSIVE, because a
##     comparison against a value that was already correct cannot fail.
## A timeout is INCONCLUSIVE too, never a pass.
## TICKS, not frames, and there may be TWO per frame: this is driven from
## `sbdTick` (via `pfxOnPanelUp`) AND from `modsTickSubtabs`, because either
## path may be the only one running depending on which flags are on. Double
## counting only shortens the wall-clock wait, so the budget is sized for the
## worst case -- 1800 ticks is >=15 s even at two per frame at 60 fps, against
## an overlay panel poll that answers every 1 s.
const SbdEnableWaitMax = 1800
const SbdMaxEnableWatch = 8
var gSbdEnGuid: seq[string] = @[]
var gSbdEnWant: seq[bool] = @[]
var gSbdEnWas: seq[int] = @[]    ## 1/0 = the manager's answer, -1 = it had none
var gSbdEnFrames = 0

proc sbdEnableWatch(guid: string; want: bool) =
  ## Arms the V3 read-back for one guid. The pre-state is sampled HERE, on the
  ## way out, because a sample taken later is a sample taken after the write.
  if gSbdEnGuid.len >= SbdMaxEnableWatch: return
  var was = -1
  case overlayModEnabled(guid)
  of ovModEnabled: was = 1
  of ovModDisabled: was = 0
  else: was = -1
  gSbdEnGuid.add guid
  gSbdEnWant.add want
  gSbdEnWas.add was
  gSbdEnFrames = 0

proc swEnableWatch(guid: string; want: bool) =
  ## Implements the forward declaration in `settingspages.nim`. The
  ## settings-pages read-back reaches V3 through this and nothing else, so
  ## there is one enable verdict for both row paths rather than two that can
  ## drift.
  sbdEnableWatch(guid, want)

proc sbdVerdictEnable() =
  ## Runs once per tick while anything is armed. Cheap: one interlocked-free
  ## table scan per armed guid, under the overlay's own short lock.
  if gSbdEnGuid.len == 0: return
  gSbdEnFrames = gSbdEnFrames + 1
  var i = 0
  var stillPending = false
  while i < gSbdEnGuid.len and i < SbdMaxEnableWatch:
    if overlayModPending(gSbdEnGuid[i]): stillPending = true
    i = i + 1
  if stillPending and gSbdEnFrames <= SbdEnableWaitMax:
    return
  if stillPending:
    warn "settings bind: V3 ENABLE INCONCLUSIVE -- the mod manager had not " &
         "confirmed " & $gSbdEnGuid.len & " queued enable/disable(s) within " &
         $SbdEnableWaitMax & " frame(s). The gesture WAS sent; whether it " &
         "took could not be read back. This is not a pass."
    gSbdEnGuid = @[]; gSbdEnWant = @[]; gSbdEnWas = @[]
    return
  var pass = 0
  var fail = 0
  var incon = 0
  var firstFail = ""
  i = 0
  while i < gSbdEnGuid.len and i < SbdMaxEnableWatch:
    let now = overlayModEnabled(gSbdEnGuid[i])
    let nowB = (if now == ovModEnabled: 1
                elif now == ovModDisabled: 0 else: -1)
    if nowB < 0:
      incon = incon + 1
    elif nowB != (if gSbdEnWant[i]: 1 else: 0):
      fail = fail + 1
      if firstFail.len == 0:
        firstFail = gSbdEnGuid[i] & " (manager reports " &
                    swBoolText(nowB == 1) & ", asked for " &
                    swBoolText(gSbdEnWant[i]) & ")"
    elif gSbdEnWas[i] < 0 or gSbdEnWas[i] == nowB:
      # It already read that way before we asked, so agreeing now proves
      # nothing about our write. Named, not counted.
      incon = incon + 1
    else:
      pass = pass + 1
    i = i + 1
  if fail > 0:
    warn "settings bind: V3 ENABLE FAIL -- " & $fail & " mod(s) did NOT end " &
         "in the state the switch asked for. First: " & firstFail & ". The " &
         "POST /aowlspt/mods/toggle went out and the manager's own answer " &
         "disagrees with it; treat the manager as the truth."
  else:
    okLog "settings bind: V3 ENABLE PASS -- " & $pass & " mod(s) CHANGED in " &
          "the mod manager's own read-back to the state the switch asked " &
          "for" &
          (if incon > 0: ", " & $incon & " INCONCLUSIVE (the manager has no " &
                         "answer for that guid, or it already read that way " &
                         "before the ask -- NOT counted as a pass)" else: "")
  gSbdEnGuid = @[]; gSbdEnWant = @[]; gSbdEnWas = @[]

proc sbdFlush() =
  ## Persist every staged edit through the SAME write the F12 overlay uses, so
  ## the mod's `onSettingsApplied` runs. Then V1.
  var wrote = 0
  var pass = 0
  var fail = 0
  var incon = 0
  var firstFail = ""
  var i = 0
  while i < gSbdRows.len and i < SbdMaxRows:
    if gSbdRows[i].staged:
      if gSbdRows[i].kind == sbdToggle:
        sbdEnqueue(gSbdRows[i].guid, gSbdRows[i].key,
                   swBoolText(gSbdRows[i].stagedB))
        gSbdRows[i].flushedB = gSbdRows[i].stagedB
      elif gSbdRows[i].kind == sbdSlider:
        sbdEnqueue(gSbdRows[i].guid, gSbdRows[i].key,
                   sbdF(gSbdRows[i].stagedF))
        gSbdRows[i].flushedF = gSbdRows[i].stagedF
      elif gSbdRows[i].kind == sbdDropdown:
        # AN INTEGER, not "2.0000". The schema key is a one-based CHOICE and
        # `tools/dlssapply.py` reads it as one; writing a float here would put
        # a value in the config that does not match what the mod declares.
        sbdEnqueue(gSbdRows[i].guid, gSbdRows[i].key,
                   $int(gSbdRows[i].stagedF))
        gSbdRows[i].flushedF = gSbdRows[i].stagedF
      else:
        # A PER-MOD ENABLED SWITCH, and it is now WRITTEN -- through the F12
        # panel's own command queue.
        #
        # THE PREVIOUS COMMENT HERE WAS WRONG, and it is worth saying why
        # rather than deleting it. It stated that the mod-enable write is
        # `GET /aowlspt/mods/enable|disable/<guid>` and that the gap was a
        # missing one-shot GET on the overlay bridge. MEASURED against the two
        # instruments that settle it -- `mods/manager/manager.nim:2295-2306`
        # (the route table) and the AOWL_CMD_TOGGLE leg of the overlay worker
        # (`abi/aowlspt_overlay.h`) -- what F12 actually sends is
        # `POST /aowlspt/mods/toggle/<guid>` `{"enabled":..}`, which takes the
        # manager's `toggleLocked` path. The enable/disable GETs are a
        # different, older route (`overrideLocked`). A native switch that must
        # do exactly what F12 does therefore needed no new verb at all: it
        # needed the same command queue, which `overlayModToggle` enters.
        gSbdRows[i].flushedB = gSbdRows[i].stagedB
        let rc = overlayModToggle(gSbdRows[i].guid, gSbdRows[i].stagedB)
        if rc == 1'i32:
          sbdEnableWatch(gSbdRows[i].guid, gSbdRows[i].stagedB)
          okLog "settings bind: mod '" & gSbdRows[i].guid & "' switched " &
                swBoolText(gSbdRows[i].stagedB) & " -- queued as " &
                "POST /aowlspt/mods/toggle/" & gSbdRows[i].guid &
                " {\"enabled\":" & swBoolText(gSbdRows[i].stagedB) & "}, the " &
                "same gesture the F12 panel queues. The manager's answer is " &
                "read back below; until it lands this is INCONCLUSIVE, not a " &
                "pass."
        else:
          warn "settings bind: mod '" & gSbdRows[i].guid & "' was switched " &
               swBoolText(gSbdRows[i].stagedB) & " on screen and NOTHING was " &
               "sent -- " &
               (if rc == 0'i32:
                  "the overlay's mod table has no row for that guid, so there " &
                  "is nothing to ask the manager about (the panel poll has " &
                  "not run, or the manager does not know this mod)"
                elif rc == -1'i32:
                  "the row is PROTECTED; the manager refuses to switch off " &
                  "the mod serving the request, and so does this"
                else:
                  "this overlay was started with no backend port, so it is " &
                  "read-only and has nothing to ask") &
               ". The switch is honest about having done nothing rather than " &
               "appearing to work."
      gSbdRows[i].flushed = true
      gSbdRows[i].staged = false
      wrote = wrote + 1
      # The mod owning this row had a REAL edit persisted. Recorded here and
      # only here -- the SAVE prefix fires on presses that changed nothing.
      sbdNoteSaved(gSbdRows[i].guid)
      # V1, immediately: does the LIVE control agree with what was just sent?
      # An `sbdEnable` row is a toggle on screen, so it reads back like one --
      # what differs is only where its value would be WRITTEN.
      if gSbdRows[i].kind == sbdDropdown:
        # Through the GAME'S OWN getter, at a different address from the
        # setter that wrote it.
        let (ok3, zero) = nuDropDownIndex(gSbdRows[i].read)
        if not ok3: incon = incon + 1
        elif float32(zero + 1'i32) == gSbdRows[i].flushedF: pass = pass + 1
        else:
          fail = fail + 1
          if firstFail.len == 0:
            firstFail = gSbdRows[i].key & " (dropdown reads " &
                        $(zero + 1'i32) & ", wrote " &
                        $int(gSbdRows[i].flushedF) & ")"
      elif gSbdRows[i].kind != sbdSlider:
        var lv = false
        if not sbdReadLiveB(i, lv): incon = incon + 1
        elif lv == gSbdRows[i].flushedB: pass = pass + 1
        else:
          fail = fail + 1
          if firstFail.len == 0:
            firstFail = gSbdRows[i].key & " (control reads " & swBoolText(lv) &
                        ", wrote " & swBoolText(gSbdRows[i].flushedB) & ")"
      else:
        var lv = 0.0'f32
        if not sbdReadLiveF(i, lv): incon = incon + 1
        else:
          let span = (if gSbdRows[i].hi > gSbdRows[i].lo:
                        gSbdRows[i].hi - gSbdRows[i].lo else: 1.0'f32)
          let d = (if lv > gSbdRows[i].flushedF: lv - gSbdRows[i].flushedF
                   else: gSbdRows[i].flushedF - lv)
          if d <= SbdSliderEps * span * 4.0'f32: pass = pass + 1
          else:
            fail = fail + 1
            if firstFail.len == 0:
              firstFail = gSbdRows[i].key & " (control reads " & sbdF(lv) &
                          ", wrote " & sbdF(gSbdRows[i].flushedF) & ")"
    i = i + 1
  if wrote == 0:
    # NOT a pass and not silence. With nothing staged there is nothing for V1
    # or V2 to judge, so the honest verdict is INCONCLUSIVE plus the census
    # that says WHY it was empty -- a registry of 0 and a registry of 27 that
    # saw no matching event are different bugs and used to print the same line.
    warn "settings bind: SAVE #" & $gSbdSaveCount & " flushed NOTHING -- " &
         sbdCensus() & ". V1/V2 are INCONCLUSIVE, not PASS. Read it as: " &
         "registry=0 means no row ever registered (the rows are on screen and " &
         "bound to nothing); toggleEvents=0 means the Toggle::Set drain is " &
         "not reaching this feature at all (that detour belongs to nativeTabs " &
         "-- if that feature is off, nothing is bound); toggleEvents>0 with " &
         "matched=0 means the event arrives and the pointer does not match, " &
         "and a BIND MISS line names the row."
    return
  if fail > 0:
    warn "settings bind: SAVE #" & $gSbdSaveCount &
         " V1 LIVE FAIL -- " & $fail & " of " & $wrote &
         " flushed row(s) do NOT read back as the value that was written. " &
         "First: " & firstFail & ". The write went out anyway, which means " &
         "the config and the screen now disagree; treat the SCREEN as wrong " &
         "and the config as what the mod received."
  else:
    okLog "settings bind: SAVE #" & $gSbdSaveCount &
          " V1 LIVE PASS -- " & $pass & "/" & $wrote &
          " flushed row(s) read back through the game's own getter as the " &
          "value written" &
          (if incon > 0: ", " & $incon & " INCONCLUSIVE (the control could " &
                         "not be read; NOT counted as a pass)" else: "")
  # V2 is armed only once the QUEUE has drained -- see `sbdPump`. Arming it
  # here would read the config back while our own writes were still in flight
  # and call the resulting disagreement a FAIL.
  gSbdPendingConfigArm = true

proc sbdVerdictConfig(): bool =
  ## V2. Returns true once it could actually answer. Every flushed row is
  ## compared against the CONFIG as the schema endpoint now reports it -- the
  ## same accessor the seed reads. A row whose control changed but whose config
  ## did not is exactly what this prints, by name.
  ## GENERIC OVER GUIDS. There is no single mod here: the PostFX rows are one
  ## consumer, the per-mod setting rows of the MODS tab will be many, and the
  ## registry is keyed by (modGuid, key) throughout. This answers only when a
  ## parsed page exists for EVERY guid that has a flushed row -- a partial
  ## answer would report the mods it could not see as a PASS.
  result = false
  var seen = 0
  var missing = ""
  var k = 0
  while k < gSbdRows.len and k < SbdMaxRows:
    if gSbdRows[k].flushed and gSbdRows[k].kind != sbdEnable:
      seen = seen + 1
      var pi = -1
      if not sbdPageFor(gSbdRows[k].guid, pi):
        if missing.len == 0: missing = gSbdRows[k].guid
    k = k + 1
  if seen == 0: return
  if missing.len != 0: return
  var pass = 0
  var fail = 0
  var incon = 0
  var firstFail = ""
  var n = 0
  var i = 0
  while i < gSbdRows.len and i < SbdMaxRows:
    if gSbdRows[i].flushed and gSbdRows[i].kind != sbdEnable:
      n = n + 1
      if gSbdRows[i].kind == sbdToggle:
        var cv = false
        if not sbdConfigB(gSbdRows[i].guid, gSbdRows[i].key, cv):
          incon = incon + 1
        elif cv == gSbdRows[i].flushedB: pass = pass + 1
        else:
          fail = fail + 1
          if firstFail.len == 0:
            firstFail = gSbdRows[i].key & " (config reads " & swBoolText(cv) &
                        ", control was left at " &
                        swBoolText(gSbdRows[i].flushedB) & ")"
      else:
        var cv = 0.0'f32
        if not sbdConfigF(gSbdRows[i].guid, gSbdRows[i].key, cv):
          incon = incon + 1
        else:
          let span = (if gSbdRows[i].hi > gSbdRows[i].lo:
                        gSbdRows[i].hi - gSbdRows[i].lo else: 1.0'f32)
          let d = (if cv > gSbdRows[i].flushedF: cv - gSbdRows[i].flushedF
                   else: gSbdRows[i].flushedF - cv)
          if d <= SbdSliderEps * span * 4.0'f32: pass = pass + 1
          else:
            fail = fail + 1
            if firstFail.len == 0:
              firstFail = gSbdRows[i].key & " (config reads " & sbdF(cv) &
                          ", control was left at " &
                          sbdF(gSbdRows[i].flushedF) & ")"
    i = i + 1
  if n == 0: return
  # The page may be the one that was already there BEFORE the write. That makes
  # a PASS unearned and a FAIL premature, so a page that agrees with the
  # PRE-flush value on every row is not accepted as an answer yet.
  if fail > 0:
    warn "settings bind: V2 CONFIG FAIL -- " & $fail & " of " & $n &
         " row(s) changed on screen and did NOT change in the mod's config. " &
         "First: " & firstFail & ". The control moved, the SAVE fired and the " &
         "POST to /aowlspt/settings/<guid> did not take."
  else:
    okLog "settings bind: V2 CONFIG PASS -- " & $pass & "/" & $n &
          " flushed row(s) read back from /aowlspt/settings/<guid> as the " &
          "value written" &
          (if incon > 0: ", " & $incon & " INCONCLUSIVE (the key was absent " &
                         "from the page; NOT counted as a pass)" else: "")
  true

proc sbdTick*() =
  ## The drain rider. Idle cost with the flag off is one boolean compare.
  sbdInitFlags()
  # V3 FIRST, AND OUTSIDE THE READY GATE. The enable watch is armed by TWO
  # callers -- `sbdFlush` here and `swReadBackPage` in `settingspages.nim` --
  # and the second is behind `settingsPages`/`nativeTabsMods`, not behind
  # `settingsRowsBind`. Draining it only when this feature is on would let an
  # enable armed by the pages path sit in the table forever, fill it at
  # SbdMaxEnableWatch, and then silently drop every later one: a verdict that
  # stops running looks exactly like a verdict that keeps passing.
  # Idle cost when nothing is armed is one length compare.
  sbdVerdictEnable()
  if not sbdReady(): return
  # BEFORE the save drain, so a selection changed on the same frame as the
  # press is staged in time to be flushed by it.
  sbdPollDropdowns()
  if gSbdSaveSeen:
    gSbdSaveSeen = false
    sbdFlush()
    return
  # ONE queued write released per tick, never two, and never one while another
  # is in flight -- the POST slot is shared and single.
  let drained = sbdPump()
  if gSbdPendingConfigArm and drained:
    gSbdPendingConfigArm = false
    gSbdWantConfigCheck = true
    gSbdConfigWaitFrames = 0
  if gSbdWantConfigCheck:
    gSbdConfigWaitFrames = gSbdConfigWaitFrames + 1
    if sbdVerdictConfig():
      gSbdWantConfigCheck = false
    elif gSbdConfigWaitFrames > SbdConfigWaitMax:
      gSbdWantConfigCheck = false
      warn "settings bind: V2 CONFIG INCONCLUSIVE -- no schema page arrived " &
           "for every guid with a flushed row within " & $SbdConfigWaitMax &
           " frame(s) after the save, so whether the config actually took the " &
           "written values COULD NOT BE CHECKED. This is not a pass. The page " &
           "fetch lives behind `modSettingsRender`; with that flag off there " &
           "is no accessor here to read the config back through."

# ---------------------------------------------------------------------------
# THE BINDS. Two detours on two DIFFERENT functions, never two on one.
# ---------------------------------------------------------------------------

proc sbdBind*(verbose: bool; toggleDrainLive: bool) =
  ## Called once, from the same place `nativetabs.nim` binds its own drain --
  ## i.e. after `cProPrimeAll()` and after GameAssembly.dll is loaded. Binding
  ## earlier makes the prologue snapshot capture fail and every verify then
  ## fails closed, which reads as a build mismatch and is not one.
  sbdInitFlags()
  if gSbdBound or not sbdReady(): return
  gSbdBound = true
  # THE DEPENDENCY, stated before anything is bound. The toggle half of this
  # feature has no detour of its own by design; it drains the one `nativetabs`
  # installs on `UnityEngine.UI.Toggle::Set`. If that did not bind -- because
  # `nativeTabs` is off, or because its own bind refused -- then every toggle
  # row registered below is inert, and NOTHING in the log would have said so.
  # MEASURED consequence, live 18:36: a row whose `m_IsOn` provably went 1 -> 0
  # produced no line of any kind.
  if not toggleDrainLive:
    warn "settings bind: the UnityEngine.UI.Toggle::Set drain is NOT LIVE -- " &
         "nativeTabs did not bind it (that feature owns the only detour on " &
         "that function; a second one would overwrite its trampoline). Every " &
         "TOGGLE row registered by this feature is therefore inert: it will " &
         "move on screen and stage nothing. Slider rows are unaffected -- " &
         "they use this feature's own prefix on Slider::Set. Turn on " &
         "`nativeTabs` to make toggle rows bind."
  else:
    okLog "settings bind: the UnityEngine.UI.Toggle::Set drain is LIVE " &
          "(nativeTabs slot " & $gNtToggleSlot & "); toggle rows will stage."
  let fs = nuFn(NuTSliderSet)
  if fs == nil:
    warn "settings bind: UnityEngine.UI.Slider::Set could not be bound -- " &
         nuWhyName(cNuWhyOf(NuTSliderSet)) & ". Only a PROLOGUE MISMATCH " &
         "would mean this game build changed; every other reason is a fault " &
         "in our own host, most likely bind ORDER. Slider rows are NOT bound " &
         "and moving one changes nothing. NOTHING was patched."
  elif attachDrain("UnityEngine.UI.Slider::Set", fs, cast[Il2CppMethod](0),
                   false, verbose, 32'i32):
    if not gSbdSaidBind:
      okLog "settings bind: bound a read-only PREFIX on " &
            "UnityEngine.UI.Slider::Set @0x55B44A0 (UNIQUE, 4 register " &
            "slots). It never suppresses the original, ignores " &
            "sendCallback=false (which is what SetValueWithoutNotify and the " &
            "game's own restore pass), and for a foreign slider does at most " &
            $SbdMaxRows & " pointer compares and returns."
  else:
    warn "settings bind: the Slider::Set detour did NOT bind; slider rows " &
         "will not be seen and moving one changes nothing. Nothing was changed."
  let fv = nuFn(NuTSaveSettings)
  if fv == nil:
    warn "settings bind: SettingsScreenController::SaveSettings could not be " &
         "bound -- " & nuWhyName(cNuWhyOf(NuTSaveSettings)) & ". Edits will " &
         "be staged and NEVER PERSISTED, so every row is read-only in effect. " &
         "NOTHING was patched."
  elif attachDrain("EFT.UI.Settings.SettingsScreenController::SaveSettings",
                   fv, cast[Il2CppMethod](0), false, verbose, 33'i32):
    gSbdSaidBind = true
    okLog "settings bind: bound a read-only PREFIX on " &
          "SettingsScreenController::SaveSettings @0x1721E20 (UNIQUE, arity " &
          "0). It sets one flag; the writes and the verdict happen on the " &
          "next drain tick, off the game's own save path."
  else:
    warn "settings bind: the SaveSettings detour did NOT bind. Edits are " &
         "staged and never persisted; nothing was changed."

proc sbdSummary*(): string =
  if not gSbdInit: return "settings bind: not initialised"
  if not gSbdOn: return "settings bind: OFF (settingsRowsBind)"
  if gSbdOff: return "settings bind: SELF-DISABLED after " & $gSbdFaults &
                     " fault(s)"
  var staged = 0
  var flushed = 0
  var seeded = 0
  var i = 0
  while i < gSbdRows.len and i < SbdMaxRows:
    if gSbdRows[i].staged: staged = staged + 1
    if gSbdRows[i].flushed: flushed = flushed + 1
    if gSbdRows[i].fromConfig: seeded = seeded + 1
    i = i + 1
  sbdCensus() & " | settings bind: " & $gSbdRows.len &
    " row(s) bound, " & $seeded &
    " seeded FROM CONFIG (the rest show the schema's DECLARED DEFAULT), " &
    $staged & " staged, " & $flushed & " written"
