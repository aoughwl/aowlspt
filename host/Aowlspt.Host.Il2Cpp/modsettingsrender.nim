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

const
  cModSetMaxMods = 16       ## bounds the fetch cycle, not the mods installed
  cModSetPollMs = 300       ## floored to 250 by `aowl_ov_sync_start` anyway
  cModSetMaxFaults = 4      ## faults across the whole feature, not per mod
  cModSetStallMs = 8000'u64 ## no answer in this long on one step -> give up
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
var gModSetPhase = msIdle
var gModSetArmedAt = 0'u64
var gModSetMods: seq[tuple[guid: string, name: string]] = @[]
var gModSetIdx = 0
var gModSetArmedAttempts = 0'i32  ## `overlaySyncAttempts()` read right after arming
var gModSetInstrumentTicks = 0     ## logs raw slot state for the first few ticks of a step

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
    # read it back (only `swkToggle` is wired there) -- true today, and
    # marking it not-implemented here would be a lie about what the BACKEND
    # supports. The gap is in the renderer, not the schema, so it is left
    # `implemented` and simply inert until that renderer gains slider
    # seeding; this is the same honesty the free-text/keybind case below
    # states outright, just for a different reason.
  else:
    # enum / string / keybind / anything else: no native widget exists to
    # clone (`SETTINGS-CONTROLS-RE.md` sec.4 lists what does). Drawn and
    # labelled, never bound, and said so on the row itself -- the degrade
    # this task asked to be made VISIBLE rather than silently dropped.
    row.kind = swkStub
    row.implemented = false
  result = true

proc modSetParseSchema(doc: string; guid, name: string; page: var SwPage): bool =
  var items: seq[string] = @[]
  if not pathItems(doc, "", items):
    return false
  page = SwPage(id: "mod:" & guid, title: name, modGuid: guid)
  var i = 0
  while i < items.len and page.rows.len < cSwMaxRows:
    var row = SwRow()
    if modSetParseRow(items[i], row):
      page.rows.add row
    i = i + 1
  result = true

proc modSetTick(now: uint64) =
  ## Advances the fetch cycle by exactly one step. Called once per host tick;
  ## every branch either returns immediately (nothing to do yet) or performs
  ## one bounded action -- never a loop that could spend an unbounded slice
  ## of this thread's time.
  if not gModSetOn or gModSetOff or gModSetPhase == msDone:
    return
  if gSyncMs <= 0:
    # No backend configured at all -- nothing to fetch and no slot exists to
    # borrow. Declines rather than spins.
    modSetFinish("no backend configured")
    return
  case gModSetPhase
  of msDone:
    discard
  of msIdle:
    gModSetPhase = msIndex
    gModSetArmedAt = now
    gModSetArmedAttempts = overlaySyncAttempts()
    gModSetInstrumentTicks = 0
    overlaySyncStart("/aowlspt/settings/index", int32(cModSetPollMs))
    okLog "mod settings render: borrowing the sync slot for " &
          "/aowlspt/settings/index (worker attempt counter at arm: " &
          $gModSetArmedAttempts & ")"
  of msIndex:
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
    let doc = overlaySyncTake()
    let attempts = overlaySyncAttempts() - gModSetArmedAttempts
    if gModSetInstrumentTicks < 20:
      inc gModSetInstrumentTicks
      okLog "mod settings render: schema step ('" & gModSetMods[gModSetIdx].guid &
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
    let m = gModSetMods[gModSetIdx]
    var page = SwPage()
    if modSetParseSchema(doc, m.guid, m.name, page):
      swPageRegister(page)
      okLog "mod settings render: page '" & m.guid & "' -> " &
            $page.rows.len & " row(s)"
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
