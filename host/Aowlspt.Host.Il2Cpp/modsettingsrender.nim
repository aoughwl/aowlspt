# modsettingsrender.nim -- fetches each mod's schema from the backend and
# renders it into the real settings screen via `settingspages.nim`'s existing
# cloned-control renderer, then writes an edit back to the mod that owns it.
#
# `include`d into `aowlhost.nim` AFTER `gSyncPath`/`gSyncBase`/`gSyncMs` are
# declared and BEFORE `hostMain`, so it can read/restore the mod-control sync
# state and so `hostMain`'s tick loop can call `modSetTick`/`modSetDrainPost`.
# `settingspages.nim`, included earlier, forward-declares `modSetQueueWrite`
# for exactly this file to implement.
#
# THE SLOT PROBLEM (fact #111): the overlay's GET feed is single-path-in-
# flight, and it is ALREADY in continuous use by live mod control
# (`gSyncPath`, driven from `hostMain`). This feature does not get a slot of
# its own -- it borrows the one that exists, for a short, FINITE, sequenced
# cycle (index, then each mod's schema, capped), and hands it back to mod
# control the moment the cycle ends or gives up. It never polls in a loop.
#
# The write leg is independent: `overlayPostStart`/`overlayPostTake` are a
# separate single-shot slot (`abi/aowlspt_overlay.h`, `aowl_ov_post_*`), so an
# edit never contends with the read cycle above.
#
# SAFETY: default OFF (`modSettingsRender`). Runs off the host's own tick
# thread, never the Unity main thread, and never blocks it -- every step here
# is "read what already arrived" or "arm the next request", not a network
# call made inline. Capped: at most `cModSetMaxMods` mods, one schema page
# each; a stall on any one step self-disables after `cModSetMaxFaults`. A
# failed parse is logged and skipped, never guessed at.

import jsonpath

# The guard trampoline, in C, exactly as `colorwidget.nim` does it -- rather
# than casting a Nim proc to a pointer at the call site, which is a cast the
# backend is under no obligation to make mean what it looks like.
{.emit: """
extern void* aowl_modset_tick_body(void* a);
static void* aowl_modset_tick_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_modset_tick_body, a);
}
""".}

proc cModSetTickGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_modset_tick_guarded", nodecl.}

const
  cModSetMaxMods = 16       ## bounds the fetch cycle, not the mods installed
  cModSetPollMs = 300       ## floored to 250 by `aowl_ov_sync_start` anyway
  cModSetMaxFaults = 4      ## faults across the whole feature, not per mod
  cModSetStallMs = 8000'u64 ## no answer in this long on one step -> give up
  cModSetTotalBorrowMs = 6000'u64
    ## ...and no more than this for the WHOLE cycle, however many steps stall.
    ## MEASURED: `cModSetStallMs` is per STEP, and three mods each burning the
    ## full 8s held the shared slot from 0:00:02.1 to 0:00:26.5 -- 24 seconds
    ## during which `modSetOwnsSlot` gates `takeModSet` off and live mod
    ## control is blind. That starvation, not the parse, is what moved a mod
    ## `FreeLibrary` from 4.8s into the character-select transition in two
    ## crash runs. A per-step budget cannot bound the borrow; only this can.
  ## Measured live (coordinator report): the worker took ~2.1s of
  ## changeover latency before it fired the FIRST request for a newly
  ## armed path, on top of its own ~375ms poll cadence -- the budget must
  ## clear the changeover plus a few poll periods, not just the RTT of one
  ## request. This is now a secondary safeguard: the primary fix is that
  ## `takeModSet` no longer steals this step's answer (see `hostMain`),
  ## which was the actual cause of every prior timeout.

type
  ModSetPhase = enum
    msIdle      ## nothing started; waiting for `modSettingsRender` + a poll
    msIndex     ## the index request is armed / in flight
    msSchema    ## one mod's schema request is armed / in flight
    msDone      ## finished (success or gave up); slot handed back

var gModSetOn = false        ## `modSettingsRender` -- read once at boot
var gModSetOff = false       ## self-disabled after `cModSetMaxFaults`
var gModSetFaults = 0
var gModSetColorRowsSeen = 0
  ## How many `color` rows this host has CLASSIFIED off a fetched schema, ever.
  ## Exists so `cwVerdict` can tell "no schema carried a colour row" from "the
  ## schema fetch never ran at all" -- two causes that produced one identical
  ## INCONCLUSIVE line, and the second one is what was actually true.
var gModSetColorRowsRefused = 0
  ## ...and how many of those were demoted because their value did not parse.
var gModSetPagesParsed = 0
var gModSetPhase = msIdle
var gModSetArmedAt = 0'u64
var gModSetMods: seq[tuple[guid: string, name: string]] = @[]
var gModSetIdx = 0
var gModSetArmedAttempts = 0'i32  ## `overlaySyncAttempts()` read right after arming
var gModSetInstrumentTicks = 0     ## logs raw slot state for the first few ticks of a step

# --- the crash-safety additions (2026-08-31) --------------------------------
#
# Turning `modSettingsRender` on took the client down at character-select with
# NO managed exception in the client's own log -- a hard native fault. The
# faulting dereference was never identified, because this path had no witness
# that survives the death: its instrumentation stops after 20 ticks and the
# breadcrumb ring was never armed.
#
# So this file now does three things it did not do before, and each is
# independently worth having whether or not it is the cause:
#
#  1. THE WHOLE TICK BODY RUNS UNDER ONE `aowl_p_p_seh`. It is the host's own
#     tick thread and nothing on that thread opens a guard, so there is no
#     outer guard to disarm by nesting (rule 3 is satisfied, not violated).
#     A fault becomes a REFUSAL that names its step instead of an AV.
#  2. `gModSetStep` names the step in progress at all times, so the refusal in
#     (1) -- and any future crash -- says WHERE, not merely THAT.
#  3. `swPageRegister` is NO LONGER CALLED FROM THIS THREAD. `gSwPages` is
#     read on the Unity main thread by `swPagesOnTabBuilt` and `modsBuildPages`;
#     appending to a Nim seq from here while that thread indexes it reallocates
#     the buffer under the reader, which is a use-after-free by construction.
#     Parsed pages are staged under the process lock and drained BY the Unity
#     thread. That is a real defect found while looking for the fault; it is
#     NOT established to be the crash, and this file does not claim it is.
var gModSetStep = "not started"
var gModSetGuardFaults = 0
const cModSetMaxGuardFaults = 2
  ## Deliberately lower than `cModSetMaxFaults`. A parse that gave up is a
  ## disappointment; an access violation inside our own tick is a bug, and the
  ## second one buys no information the first did not.
var gModSetStaged: seq[SwPage] = @[]
  ## Host thread WRITES under `cMqLock`; Unity thread DRAINS under the same
  ## lock. Nothing else touches it, and neither critical section calls anything
  ## that could take the lock again (it is not reentrant).
var gModSetStagedTotal = 0
var gModSetDrained = 0
var gModSetXsWitness = false
  ## One-shot: has the character-select transition been observed from here?
var gModSetCycleAt = 0'u64
  ## When the CYCLE (not the step) first took the shared slot.
var gModSetWaitLogged = false

proc modSetStage(p: SwPage) =
  ## Hand one parsed page to the Unity thread. Bounded by the same ceiling the
  ## fetch cycle already has, so a backend answering forever cannot grow this.
  cMqLock()
  if gModSetStaged.len < cModSetMaxMods:
    gModSetStaged.add p
    inc gModSetStagedTotal
  cMqUnlock()

proc modSetDrainStaged() =
  ## UNITY MAIN THREAD ONLY. Called from `swPagesOnTabBuilt` before it reads the
  ## registry. Copies out under the lock and registers outside it, so the lock
  ## is held for a pointer swap and never across the renderer.
  var batch: seq[SwPage] = @[]
  cMqLock()
  if gModSetStaged.len > 0:
    batch = gModSetStaged
    gModSetStaged = @[]
  cMqUnlock()
  if batch.len == 0:
    return
  var i = 0
  while i < batch.len:
    swPageRegister(batch[i])
    i = i + 1
  gModSetDrained = gModSetDrained + batch.len
  # THE DEFERRAL FIRED. This line is the proof asked for: staging without a
  # drain is a feature that never renders, and the two counters below make that
  # falsifiable -- `staged` above `drained` after a Game-tab visit is a FAIL,
  # not a silence.
  okLog "mod settings render: drained " & $batch.len & " staged mod page(s) " &
        "onto the Unity main thread (staged=" & $gModSetStagedTotal &
        " drained=" & $gModSetDrained & "); the deferral fired"

proc modSetParseF64(s: string; dflt: float64): float64 =
  ## A tiny, dependency-free float parse -- this file has no `strutils`
  ## import elsewhere in this codebase to lean on, and a schema's `value`,
  ## `min`, `max` are always plain JSON numbers (no exponent form seen in
  ## practice), so digits, one optional leading `-`, one optional `.` is the
  ## whole grammar this needs.
  if s.len == 0:
    return dflt
  var i = 0
  var neg = false
  if s[0] == '-':
    neg = true
    i = 1
  var whole = 0.0
  var seenDigit = false
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    whole = whole * 10.0 + float64(int(s[i]) - int('0'))
    seenDigit = true
    i = i + 1
  var frac = 0.0
  var scale = 1.0
  if i < s.len and s[i] == '.':
    i = i + 1
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      scale = scale * 10.0
      frac = frac + float64(int(s[i]) - int('0')) / scale
      seenDigit = true
      i = i + 1
  if not seenDigit:
    return dflt
  result = whole + frac
  if neg:
    result = -result

proc modSetOwnsSlot(): bool =
  ## True while this feature has the shared GET slot armed for its own path
  ## and has not yet handed it back -- `takeModSet` must not call
  ## `overlaySyncTake` during this window, because the two share ONE
  ## serial/taken cursor and whichever calls first on a given tick consumes
  ## the body, leaving the other with nothing (see the call site in
  ## `hostMain`).
  gModSetOn and not gModSetOff and
    (gModSetPhase == msIndex or gModSetPhase == msSchema)

proc modSetFault(why: string) =
  gModSetFaults = gModSetFaults + 1
  warn "mod settings render: " & why & " (" & $gModSetFaults & " of " &
       $cModSetMaxFaults & ")"
  if gModSetFaults >= cModSetMaxFaults and not gModSetOff:
    gModSetOff = true
    warn "mod settings render: DISABLED after " & $gModSetFaults &
         " fault(s) this session"

proc modSetFinish(note: string) =
  ## Ends the cycle, success or not, and hands the shared GET slot back to
  ## live mod control -- the thing that was using it before this feature
  ## borrowed it, and the thing every OTHER host feature assumes still owns
  ## it. Skipped only when mod control never claimed a path either, which
  ## means there is nothing to hand back to.
  gModSetPhase = msDone
  if gSyncPath.len > 0 and gSyncMs > 0:
    overlaySyncStart(gSyncPath, int32(gSyncMs))
  okLog "mod settings render: " & note & "; sync slot returned to mod control"

## One JSON object -> one `SwRow`. Field names match `AowlOvSItem`'s JSON,
## the same shape the F12 overlay's own settings panel already reads (see
## `aowl_ov_read_one_item`), because both sides read the exact same backend
## response.
proc modSetHexVal(c: char): int =
  ## -1 for "not a hex digit". Three outcomes collapse to two safely here only
  ## because the caller treats -1 as a hard parse failure, never as 0.
  if c >= '0' and c <= '9': return int(c) - int('0')
  if c >= 'a' and c <= 'f': return 10 + int(c) - int('a')
  if c >= 'A' and c <= 'F': return 10 + int(c) - int('A')
  -1

proc modSetParseColor(s: string; r, g, b, a: var float32;
                      hasA: var bool): bool =
  ## `#rgb`, `#rrggbb`, `#rrggbbaa`, with or without the leading `#`. This is
  ## the format `colorSetting(format=)` in `aowl/src/aowlspt/settings.nim`
  ## declares and the one the web picker writes, so the two UIs read and write
  ## the same string.
  ##
  ## STRICT ON PURPOSE. Every unrecognised shape is a refusal, not a fallback
  ## to black: a colour control that silently shows black for a value it could
  ## not read looks exactly like a colour control showing a black setting, and
  ## the first drag would persist the invention over the real value.
  r = 0.0'f32; g = 0.0'f32; b = 0.0'f32; a = 1.0'f32
  hasA = false
  var t = s
  if t.len > 0 and t[0] == '#': t = t[1 .. t.len - 1]
  # ---- the `rgb` shape: `r,g,b` / `r,g,b,a`, components 0..1 -------------
  #
  # THIS BRANCH IS WHY THE FEATURE NEVER FIRED. `cColorFmtRgb` is the DEFAULT
  # format every `colorSetting` gets, and until now this parser understood hex
  # only -- so a default-format colour row failed to parse, was demoted to
  # `swkStub`/`implemented = false` below, and rendered as an unbound text row
  # carrying the raw value, which is exactly the reported symptom. It is a
  # shape test, not a format-field test, on purpose: the row's declared format
  # says what to WRITE, and trusting it to decide what to READ would turn one
  # stale field into an unreadable colour.
  var comma = false
  for ch in t:
    if ch == ',': comma = true
  if comma:
    var parts: seq[string] = @[]
    var cur = ""
    for ch in t:                          # capped: `t` is a settings value
      if ch == ',':
        parts.add cur
        cur = ""
      else:
        cur.add ch
    parts.add cur
    if parts.len != 3 and parts.len != 4: return false
    for p in parts:
      if p.len == 0: return false
    r = float32(modSetParseF64(parts[0], -1.0))
    g = float32(modSetParseF64(parts[1], -1.0))
    b = float32(modSetParseF64(parts[2], -1.0))
    if parts.len == 4:
      a = float32(modSetParseF64(parts[3], -1.0))
      hasA = true
    # STRICT, like the hex leg: an out-of-range component means the text was
    # not a 0..1 colour at all (or `modSetParseF64` fell back), and inventing a
    # clamped colour for it would put a control on screen showing a value the
    # mod does not hold.
    if r < 0.0'f32 or r > 1.0'f32 or g < 0.0'f32 or g > 1.0'f32 or
       b < 0.0'f32 or b > 1.0'f32 or a < 0.0'f32 or a > 1.0'f32:
      return false
    return true
  if t.len != 3 and t.len != 6 and t.len != 8: return false
  var n: seq[int] = @[]
  var i = 0
  while i < t.len:                        # capped: t.len is 3, 6 or 8
    let v = modSetHexVal(t[i])
    if v < 0: return false
    n.add v
    i = i + 1
  if t.len == 3:
    # `#abc` is `#aabbcc`, the CSS rule -- doubling the nibble, NOT shifting it
    # left by four, which would make `#fff` 0xF0F0F0 instead of white.
    r = float32(n[0] * 17) / 255.0'f32
    g = float32(n[1] * 17) / 255.0'f32
    b = float32(n[2] * 17) / 255.0'f32
    return true
  r = float32(n[0] * 16 + n[1]) / 255.0'f32
  g = float32(n[2] * 16 + n[3]) / 255.0'f32
  b = float32(n[4] * 16 + n[5]) / 255.0'f32
  if t.len == 8:
    a = float32(n[6] * 16 + n[7]) / 255.0'f32
    hasA = true
  true

proc modSetParseRow(obj: string; row: var SwRow): bool =
  row = SwRow(kind: swkStub, implemented: true)
  if not pathGet(obj, "key", row.key) or row.key.len == 0:
    return false
  if not pathGet(obj, "label", row.label) or row.label.len == 0:
    row.label = row.key
  var t = ""
  discard pathGet(obj, "type", t)
  var v = ""
  if not pathGet(obj, "value", v):
    discard pathGet(obj, "default", v)
  var implStr = ""
  if pathGet(obj, "implemented", implStr) and implStr == "false":
    row.implemented = false
  discard pathGet(obj, "category", row.category)
  case t
  of "bool":
    row.kind = swkToggle
    row.bval = (v == "true")
  of "float", "int":
    row.kind = swkSlider
    row.fval = modSetParseF64(v, 0.0)
    var loS = ""
    var hiS = ""
    if pathGet(obj, "min", loS): row.lo = modSetParseF64(loS, 0.0)
    if pathGet(obj, "max", hiS): row.hi = modSetParseF64(hiS, row.lo)
    # `swRenderPage` clones and labels a slider row but does not yet seed or
    # read it back (only `swkToggle` is wired there) -- MEASURED, not assumed:
    # neither `swSeedToggle`'s slider counterpart nor a slider branch in
    # `swReadBackPage` exists. Closing that needs a byte-verified slider-value
    # field offset this task has not obtained, so per rule 8 (never blind-
    # write) it is left unseeded rather than guessed at -- and marked
    # `implemented = false` here so the player sees the same honest
    # "(not done yet)" suffix the free-text/keybind case gets below, instead
    # of a slider that silently shows the DONOR's value and does nothing.
    row.implemented = false
  of "color", "colour":
    # THE COLOUR ROW. Until 2026-08-31 this fell through to the `else` below
    # and rendered as `swkStub`/`implemented = false` -- an honest "(not done
    # yet)" for a setting the WEB ui could already edit. It is now a real
    # control, and the reason it could become one is that it does NOT need a
    # game widget to clone: `colorwidget.nim` BUILDS it out of nuikit panels
    # and labels, which is a proven path (IMAGEPROOF PASS), where cloning a
    # colour control was blocked because the stock settings screen has none.
    #
    # `implemented` stays TRUE, and that is a claim this file is entitled to
    # make only because the row is seeded at render time and read back from
    # the LIVE swatch in `swReadBackPage` -- not because a widget was drawn.
    # If `cwBuildForRow` refuses, `swRenderPage` clears `seeded` and warns; the
    # row then displays but casts no vote.
    row.kind = swkColor
    row.declaredColor = true
    # THE FORMAT, carried rather than assumed. `swReadBackPage` used to POST
    # `#rrggbb` for EVERY colour row regardless of what the mod declared, so an
    # in-game edit of a `hex` row (mods/maps, whose reader wants exactly six
    # digits and no `#`) or of an `rgb` row silently wrote a shape the owning
    # mod cannot read -- the setting reverts on the next read and looks like it
    # did not persist. Defaulted through the SAME rule as the producer
    # (`normalizeColorFormat` in aowl/src/aowlspt/settings.nim): unknown or
    # absent means `rgb`, never "whatever this file happens to write".
    row.cfmt = cSwColorFmtRgb
    var fmtS = ""
    if pathGet(obj, "colorFormat", fmtS):
      if fmtS == cSwColorFmtHex or fmtS == cSwColorFmtHexHash:
        row.cfmt = fmtS
    inc gModSetColorRowsSeen
    if not modSetParseColor(v, row.cr, row.cg, row.cb, row.ca, row.cHasA):
      # An unparseable colour is NOT rendered as a colour. Falling back to a
      # visible default would put a control on screen showing a value the mod
      # does not hold, and the first drag would then persist that invention.
      row.kind = swkStub
      row.implemented = false
      inc gModSetColorRowsRefused
      row.label = row.label & " [unreadable colour '" & v & "']"
  else:
    # enum / string / keybind / anything else: no native widget exists to
    # clone (`SETTINGS-CONTROLS-RE.md` sec.4 lists what does). Drawn and
    # labelled, never bound, and said so on the row itself -- the degrade
    # this task asked to be made VISIBLE rather than silently dropped.
    row.kind = swkStub
    row.implemented = false
  result = true

proc modSetGroupByCategory(rows: seq[SwRow]): seq[SwRow] =
  ## Buckets rows by `category`, preserving each category's first-seen order,
  ## and inserts one HEADER row (kind=swkStub, implemented=true so it gets no
  ## "(not done yet)" suffix) ahead of each group -- reusing the existing
  ## renderer and the existing `swkStub` kind rather than adding a second
  ## rendering path. This is the whole "sections within a page" feature: no
  ## code in `swRenderPage`/`swCloneRow`/`modsRelabelRow` needs to know a
  ## header exists, because it is just another row to them.
  ##
  ## Rows with no category ("") are left ungrouped, in their original order,
  ## AT THE FRONT -- so a schema that never sets `category` (every page
  ## except a fetched mod's, today) renders exactly as it did before this
  ## function existed.
  result = @[]
  var i = 0
  while i < rows.len and result.len < cSwMaxRows:
    if rows[i].category.len == 0:
      result.add rows[i]
    i = i + 1
  var cats: seq[string] = @[]
  i = 0
  while i < rows.len:
    let c = rows[i].category
    if c.len > 0:
      var seen = false
      for existing in cats:
        if existing == c:
          seen = true
          break
      if not seen:
        cats.add c
    i = i + 1
  var ci = 0
  while ci < cats.len and result.len < cSwMaxRows:
    result.add SwRow(kind: swkStub, implemented: true,
                     label: "-- " & cats[ci] & " --", key: "",
                     category: cats[ci])
    var j = 0
    while j < rows.len and result.len < cSwMaxRows:
      if rows[j].category == cats[ci]:
        result.add rows[j]
      j = j + 1
    ci = ci + 1

proc modSetParseSchema(doc: string; guid, name: string; page: var SwPage): bool =
  var items: seq[string] = @[]
  if not pathItems(doc, "", items):
    return false
  page = SwPage(id: "mod:" & guid, title: name, modGuid: guid)
  var rawRows: seq[SwRow] = @[]
  var i = 0
  while i < items.len and rawRows.len < cSwMaxRows:
    var row = SwRow()
    if modSetParseRow(items[i], row):
      rawRows.add row
    i = i + 1
  page.rows = modSetGroupByCategory(rawRows)
  # THE PER-MOD ENABLED SWITCH, first row on the page.
  #
  # It is NOT part of the schema and must not be: the schema is the mod's own
  # settings, and whether the mod runs at all belongs to the mod manager. It is
  # prepended here, where every mod page is built, so there is exactly one
  # place a page can acquire one -- rather than in the renderer, where it would
  # have to be suppressed for host pages, or in `modsBuildPages`, which would
  # miss any other consumer of `gSwPages`.
  #
  # SEEDED FROM THE MANAGER, NOT ASSUMED. `overlayModEnabled` answers with four
  # states and two of them are not booleans. When the manager has no answer for
  # this guid -- no panel poll yet, or a mod it does not know -- NO ROW IS
  # ADDED AT ALL. That is deliberate and it is the whole of rule 8: a switch
  # seeded from a guess is a switch that, on the next SAVE, writes the guess.
  # An absent row is visibly incomplete; a wrong one silently disables a mod.
  let ms = overlayModEnabled(guid)
  if ms == ovModEnabled or ms == ovModDisabled:
    var er = SwRow(key: "__enabled", label: "Enabled",
                   kind: swkToggle, bval: (ms == ovModEnabled),
                   implemented: true, enableRow: true)
    var withEnable: seq[SwRow] = @[er]
    var k = 0
    while k < page.rows.len and withEnable.len < cSwMaxRows:
      withEnable.add page.rows[k]
      k = k + 1
    if withEnable.len < page.rows.len + 1:
      warn "mod settings render: the ENABLED switch for '" & guid & "' cost " &
           "the last schema row its place -- the page is at the " &
           $cSwMaxRows & "-row cap. The switch is shown and one setting is " &
           "NOT. Raise cSwMaxRows rather than leaving this unsaid."
    page.rows = withEnable
  else:
    okLog "mod settings render: page '" & guid & "' gets NO enabled switch -- " &
          "the mod manager has " &
          (if ms == ovModHostOnly:
             "not answered about this guid (the row is this process's own " &
             "report of what it loaded, which is not the selection)"
           else: "no row for it at all") &
          ". A switch seeded from a guess would write the guess on the next " &
          "save; an absent switch is visibly incomplete instead."
  inc gModSetPagesParsed
  result = true

var gModSetNow = 0'u64
  ## `aowl_p_p_seh` passes exactly one opaque pointer, so the tick's clock is
  ## handed over in a global rather than smuggled through it as an integer.

proc modSetTickInner(now: uint64) =
  ## Advances the fetch cycle by exactly one step. Called once per host tick;
  ## every branch either returns immediately (nothing to do yet) or performs
  ## one bounded action -- never a loop that could spend an unbounded slice
  ## of this thread's time.
  ##
  ## NEVER CALL THIS DIRECTLY. `modSetTick` is the entry point and it is where
  ## the guard lives.
  gModSetStep = "entry"
  if not gModSetOn or gModSetOff or gModSetPhase == msDone:
    return
  if gSyncMs <= 0:
    # No backend configured at all -- nothing to fetch and no slot exists to
    # borrow. Declines rather than spins.
    modSetFinish("no backend configured")
    return
  # THE WHOLE-CYCLE DEADLINE. See `cModSetTotalBorrowMs`. Checked before the
  # step, so an over-long borrow ends on the very next tick rather than after
  # the step in progress has spent its own 8s.
  if gModSetPhase != msIdle and gModSetCycleAt > 0'u64 and
     now - gModSetCycleAt > cModSetTotalBorrowMs:
    modSetFault("the whole fetch cycle has held the shared sync slot for " &
                $(now - gModSetCycleAt) & "ms, over the " &
                $cModSetTotalBorrowMs & "ms ceiling. MEASURED CONSEQUENCE: " &
                "while this feature owns the slot, `takeModSet` is gated off " &
                "and live mod control is BLIND -- in two crash runs that " &
                "delayed a mod unload (FreeLibrary) from 4.8s into the " &
                "character-select transition at 29.5s. Giving the slot back " &
                "now matters more than the pages not yet fetched")
    modSetFinish("whole-cycle borrow ceiling reached")
    return
  case gModSetPhase
  of msDone:
    discard
  of msIdle:
    # DO NOT BORROW THE SLOT BEFORE THE MENU IS UP. Measured, from
    # `aowlspt-host.crash1.log` and `aowlspt-host.prev2.log` (two independent
    # crash runs with this flag on) against the surviving flag-off run:
    #
    #   flag OFF: "unloaded Textures"/"unloaded Call Proof" at 0:00:04.843,
    #             during the loading screen. Client lives.
    #   flag ON : the same two unloads at 0:00:29.797 / 0:00:29.484, i.e.
    #             INSIDE the character-select -> main-menu transition. Client
    #             dies 0.4-1.0s later, both times, with no managed exception.
    #
    # The delta is not the parse and not a bad offset: it is that this feature
    # armed the shared slot at 0:00:02.1 and held it to ~0:00:26.5 (three mods
    # each burning the full 8s stall budget), during which `modSetOwnsSlot`
    # gates `takeModSet` off and mod control cannot see its desired set. The
    # backend's unload instruction was therefore delivered ~25s late, and a
    # `FreeLibrary` of two mod DLLs landed in the middle of a scene teardown.
    #
    # So: wait for the menu. `gModeSkipSubmits` (modeskip.nim) is incremented
    # when the profile/mode screen has been answered, which is the transition
    # that was being damaged. After it, mod control has already drained its
    # backlog and borrowing the slot costs it nothing that matters.
    if gModeSkipSubmits <= 0:
      if not gModSetWaitLogged:
        gModSetWaitLogged = true
        okLog "mod settings render: NOT arming yet -- the character/mode " &
              "screen has not been answered. Borrowing the shared sync slot " &
              "before that starves live mod control and pushes its mod " &
              "load/unload work into the menu transition, which took the " &
              "client down twice. This is a DEFERRAL, not a decline: the " &
              "arm happens on the first tick after Submit and says so."
      return
    gModSetStep = "msIdle: arming the index fetch"
    gModSetCycleAt = now
    okLog "mod settings render: the character/mode screen has been answered " &
          "(Submit #" & $gModeSkipSubmits & "); THE DEFERRED ARM IS FIRING " &
          "NOW. Whole-cycle borrow ceiling " & $cModSetTotalBorrowMs & "ms."
    gModSetPhase = msIndex
    gModSetArmedAt = now
    gModSetArmedAttempts = overlaySyncAttempts()
    gModSetInstrumentTicks = 0
    overlaySyncStart("/aowlspt/settings/index", int32(cModSetPollMs))
    okLog "mod settings render: borrowing the sync slot for " &
          "/aowlspt/settings/index (worker attempt counter at arm: " &
          $gModSetArmedAttempts & ")"
  of msIndex:
    gModSetStep = "msIndex: overlaySyncTake"
    let doc = overlaySyncTake()
    let attempts = overlaySyncAttempts() - gModSetArmedAttempts
    if gModSetInstrumentTicks < 20:
      # Raw slot state for the first ~20 ticks of this step -- the ONLY way
      # to tell "the worker has not gotten to this path yet" from "it has
      # answered N times and something ate every one of them" without a
      # debugger attached.
      inc gModSetInstrumentTicks
      okLog "mod settings render: index step, tick " & $gModSetInstrumentTicks &
            ": worker attempts-since-arm=" & $attempts &
            " pending=" & (if doc.len > 0: $doc.len else: "0") &
            " ownsSlot=" & (if modSetOwnsSlot(): "true" else: "false")
    if doc.len == 0:
      if now - gModSetArmedAt > cModSetStallMs:
        if attempts <= 0:
          modSetFault("gave up on the settings index: the worker never " &
                      "reported a body for this path within " &
                      $cModSetStallMs & "ms (attempts-since-arm=0 -- this " &
                      "is a changeover-latency problem, not a parse or " &
                      "take() problem)")
        else:
          modSetFault("gave up on the settings index: the worker fired " &
                      $attempts & " request(s) for this path but " &
                      "overlaySyncTake() never returned a body here -- " &
                      "something else is consuming the shared slot's " &
                      "take cursor before this reads it")
        modSetFinish("gave up waiting for the index")
      return
    gModSetStep = "msIndex: parsing the index body (" & $doc.len & " byte(s))"
    var items: seq[string] = @[]
    if not pathItems(doc, "mods", items):
      modSetFault("the settings index did not parse as {\"mods\":[...]}")
      modSetFinish("index unusable")
      return
    gModSetMods = @[]
    var i = 0
    while i < items.len and gModSetMods.len < cModSetMaxMods:
      var guid = ""
      var name = ""
      discard pathGet(items[i], "guid", guid)
      discard pathGet(items[i], "name", name)
      if guid.len > 0:
        gModSetMods.add (guid: guid, name: (if name.len > 0: name else: guid))
      i = i + 1
    okLog "mod settings render: index -> " & $gModSetMods.len & " mod(s)"
    gModSetIdx = 0
    if gModSetMods.len == 0:
      modSetFinish("index named no mods")
    else:
      gModSetPhase = msSchema
      gModSetArmedAt = now
      gModSetArmedAttempts = overlaySyncAttempts()
      gModSetInstrumentTicks = 0
      overlaySyncStart("/aowlspt/settings/" & gModSetMods[0].guid,
                       int32(cModSetPollMs))
  of msSchema:
    gModSetStep = "msSchema[" & $gModSetIdx & "/" & $gModSetMods.len &
                  "]: overlaySyncTake"
    # BOUNDS, ONCE, AT THE TOP -- every read of `gModSetMods[gModSetIdx]` below
    # (the instrument line, both stall messages, the re-arm and the parse) is
    # covered by this one test. This host is built with runtime checks off, so
    # an out-of-range seq index is not an exception: it is a raw read past the
    # buffer that then dereferences whatever string header it finds, which is
    # exactly the shape of native fault being hunted here. Every branch that
    # advances `gModSetIdx` already maintains the invariant; this says so out
    # loud instead of relying on it.
    if gModSetIdx < 0 or gModSetIdx >= gModSetMods.len:
      modSetFault("REFUSING to read mod index " & $gModSetIdx & " of " &
                  $gModSetMods.len & " -- the cycle's own invariant was " &
                  "broken, which is a bug in this file, not in the backend")
      modSetFinish("index invariant broken")
      return
    let doc = overlaySyncTake()
    let attempts = overlaySyncAttempts() - gModSetArmedAttempts
    if gModSetInstrumentTicks < 20:
      inc gModSetInstrumentTicks
      okLog "mod settings render: schema step ('" &
            (if gModSetIdx >= 0 and gModSetIdx < gModSetMods.len:
               gModSetMods[gModSetIdx].guid
             else: "OUT-OF-RANGE idx " & $gModSetIdx) &
            "'), tick " & $gModSetInstrumentTicks &
            ": worker attempts-since-arm=" & $attempts &
            " pending=" & (if doc.len > 0: $doc.len else: "0")
    if doc.len == 0:
      if now - gModSetArmedAt > cModSetStallMs:
        if attempts <= 0:
          modSetFault("gave up on '" & gModSetMods[gModSetIdx].guid &
                      "': the worker never reported a body for this path " &
                      "within " & $cModSetStallMs & "ms (attempts-since-" &
                      "arm=0 -- changeover latency, not a take() problem)")
        else:
          modSetFault("gave up on '" & gModSetMods[gModSetIdx].guid &
                      "': the worker fired " & $attempts & " request(s) " &
                      "but overlaySyncTake() never returned a body here")
        # Give up on THIS mod, not the whole cycle -- one unreachable mod
        # should not cost the others their page.
        gModSetIdx = gModSetIdx + 1
        if gModSetIdx >= gModSetMods.len:
          modSetFinish("cycle finished (with at least one stall)")
        else:
          gModSetArmedAt = now
          gModSetArmedAttempts = overlaySyncAttempts()
          gModSetInstrumentTicks = 0
          overlaySyncStart("/aowlspt/settings/" & gModSetMods[gModSetIdx].guid,
                           int32(cModSetPollMs))
      return
    let m = gModSetMods[gModSetIdx]   # bounds-checked at the top of this branch
    gModSetStep = "msSchema: parsing '" & m.guid & "' (" & $doc.len & " byte(s))"
    var page = SwPage()
    if modSetParseSchema(doc, m.guid, m.name, page):
      # STAGED, not registered. `gSwPages` belongs to the Unity main thread --
      # see the note beside `gModSetStaged`.
      modSetStage(page)
      okLog "mod settings render: page '" & m.guid & "' -> " &
            $page.rows.len & " row(s), STAGED for the Unity main thread " &
            "(it renders on the next Settings -> Game visit)"
    else:
      modSetFault("mod '" & m.guid & "' schema did not parse")
    gModSetIdx = gModSetIdx + 1
    if gModSetIdx >= gModSetMods.len:
      modSetFinish("cycle finished, " & $gModSetMods.len & " mod page(s)")
    else:
      gModSetArmedAt = now
      gModSetArmedAttempts = overlaySyncAttempts()
      gModSetInstrumentTicks = 0
      overlaySyncStart("/aowlspt/settings/" & gModSetMods[gModSetIdx].guid,
                       int32(cModSetPollMs))

proc modSetTickBody(a: Il2CppPtr): Il2CppPtr {.
     exportc: "aowl_modset_tick_body", cdecl.} =
  ## The guarded body. Returns a non-nil sentinel on a normal return;
  ## `aowl_p_p_seh` returns nil when it caught an access violation, so nil is
  ## "this tick faulted" and cannot be confused with "this tick did nothing".
  modSetTickInner(gModSetNow)
  cast[Il2CppPtr](1)

proc modSetTick(now: uint64) =
  ## THE ENTRY POINT. One `aowl_p_p_seh` around the whole body and nothing
  ## nested inside it -- this runs on the host's own tick thread, which opens no
  ## guard of its own, so there is no outer guard to disarm.
  ##
  ## Known and accepted: `aowl_p_p_seh` unwinds by `longjmp`, so a fault taken
  ## while the overlay's critical section is held would leak it. The sections in
  ## question (`aowl_ov_sync_start` / `_take`) are a `memcpy` into a buffer this
  ## process owns, between an `EnterCriticalSection` and a `LeaveCriticalSection`
  ## with no allocation and no callback in between; every dereference this file
  ## can plausibly fault on is in the Nim parse work OUTSIDE them. Leaking that
  ## lock is a worse outcome than a fault but a far less likely one, and the
  ## alternative on offer today is the crash we already have.
  if not gModSetOn or gModSetOff:
    return
  gModSetNow = now
  # THE CHARACTER-SELECT WITNESS. `modeskip.nim` increments `gModeSkipSubmits`
  # when it answers the profile/mode screen -- the exact transition the client
  # died on with this flag set. Logged ONCE, from inside this feature, naming
  # the step this feature was on at the time, so "it survived" is distinguish-
  # able from "it was never running". A silence here is INCONCLUSIVE, not a
  # pass: it means either the submit never happened or this feature was already
  # finished/disabled, and the `phase=` field says which.
  if not gModSetXsWitness and gModeSkipSubmits > 0:
    gModSetXsWitness = true
    okLog "mod settings render: CHARACTER-SELECT TRANSITION SURVIVED -- the " &
          "first host tick after Submit #" & $gModeSkipSubmits &
          " reached this feature with it still armed. step='" & gModSetStep &
          "' phase=" & (case gModSetPhase
                        of msIdle: "msIdle"
                        of msIndex: "msIndex"
                        of msSchema: "msSchema"
                        of msDone: "msDone") &
          " staged=" & $gModSetStagedTotal & " drained=" & $gModSetDrained &
          " guardFaults=" & $gModSetGuardFaults & ". This tick is about to run " &
          "the step named above; if the client dies now, that step is where."
  let r = cModSetTickGuarded(nil)
  if r == nil:
    gModSetGuardFaults = gModSetGuardFaults + 1
    warn "mod settings render: ACCESS VIOLATION caught inside step '" &
         gModSetStep & "' (guard fault " & $gModSetGuardFaults & " of " &
         $cModSetMaxGuardFaults & "). The client did NOT die; this feature " &
         "refused instead. The step name above is the location."
    if gModSetGuardFaults >= cModSetMaxGuardFaults:
      gModSetOff = true
      gModSetPhase = msDone
      warn "mod settings render: DISABLED for this session after " &
           $gModSetGuardFaults & " access violation(s). The sync slot is " &
           "handed back below; nothing further is fetched, staged or rendered."
      if gSyncPath.len > 0 and gSyncMs > 0:
        overlaySyncStart(gSyncPath, int32(gSyncMs))

# ---------------------------------------------------------------------------
# The write leg
# ---------------------------------------------------------------------------

proc modSetQueueWrite(guid, key, val: string) =
  ## Implements the forward declaration in `settingspages.nim`. `val` is
  ## already a JSON literal (`swBoolText` for a toggle) -- this never guesses
  ## a type, it POSTs exactly what the renderer read off the live control.
  if not gModSetOn or gModSetOff:
    return
  let body = "{\"key\":\"" & key & "\",\"value\":" & val & "}"
  # Claim the shared POST slot for a few seconds so the client-settings bridge
  # (`settingsbridge.nim`) does not arm over this write before it has been sent.
  gSbYieldUntil = cNowMs() + 3000'u64
  overlayPostStart("/aowlspt/settings/" & guid, body)
  okLog "mod settings render: POST /aowlspt/settings/" & guid &
        " key=" & key & " value=" & val

proc modSetDrainPost() =
  ## Reads the last completed write's outcome, once, and asserts the OUTCOME
  ## rather than the write: a POST that returned 200 with a body the backend
  ## rejected is still a failure from the player's point of view, so this
  ## logs `ok` from the transport only and leaves it at that -- there is no
  ## live control here to re-read and confirm against (that already happens
  ## on the READ side, next time the page is fetched).
  if not gModSetOn or gModSetOff:
    return
  let (got, ok, _) = overlayPostTake()
  if not got:
    return
  if ok:
    okLog "mod settings render: write acknowledged"
  else:
    modSetFault("a settings write got no usable answer from the backend")
