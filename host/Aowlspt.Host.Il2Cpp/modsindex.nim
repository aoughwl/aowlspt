## ===========================================================================
## modsindex.nim -- the MODS tab's data, fetched ONCE and LAZILY.
##
## WHY THIS EXISTS RATHER THAN REUSING `modsettingsrender.nim`
## ----------------------------------------------------------
## That file fetches the same information and its pages land in the same
## `gSwPages` registry, so on the face of it this is duplication. It is not,
## and the difference is the whole point: `modSettingsRender` arms its fetch
## cycle from `hostMain`'s tick loop at BOOT, walks one HTTP round trip PER MOD
## (`msIndex`, then `msSchema` once per mod), and holds the shared sync slot
## for the duration. That is the measured crash at character-select --
## bisected: with it on the host log stops dead at [0:00:30.828] right after
## the profile Submit; with it off the run reaches [0:01:42]. It is a TIMING
## defect, not a data one, so the data path is kept and the timing is replaced.
##
## What changes here, and nothing else:
##
##   * armed ONLY when the player opens the MODS tab. A session that never
##     opens Settings pays nothing: no fetch, no slot borrow, no tick work.
##   * ONE request instead of one-per-mod. `/aowlspt/settings/index` returns
##     every mod and every setting in a single document.
##   * cached for the session. Fetched once, never re-fetched; the steady state
##     after the first open is a single enum test.
##
## THE TRANSPORT IS ALREADY OFF THE MAIN THREAD, which is why no worker is
## invented here. `overlaySyncStart` hands a path to the OVERLAY's worker
## thread and `overlaySyncTake` collects the newest whole body, so the host
## gains no HTTP client, no socket and no thread of its own. This file only
## polls an already-completed buffer from the tick, which is a memcpy.
##
## THE SLOT IS SHARED AND IS HANDED BACK ON EVERY PATH. `takeModSet` (live mod
## control) reads the same slot, and while we point it at our path that feature
## is BLIND -- `modsettingsrender.nim` measured exactly this delaying a mod
## unload (FreeLibrary) from 4.8s into the character-select transition at
## 29.5s. So the borrow is bounded by `cMiStallMs` and `miRelease` restores
## `gSyncPath` on success, on refusal and on timeout alike.
##
## WHAT IT REFUSES, LOUDLY AND FOR FREE
## ------------------------------------
## The route may not be served yet. Then this says so once and stops. A refusal
## costs the player nothing: no stock control is hidden, nothing is written,
## and the MODS tab shows the host's own pages. That is the discipline the
## postfx subtab had to learn the hard way -- a feature that cannot do its job
## must not take a working one down with it.
##
## STATUS: the route is being written now, so every line below is built against
## its DOCUMENTED shape and has never seen a real body. Nothing here is
## live-verified.
## ===========================================================================

const cMiPollMs = 250          ## worker re-poll cadence while we hold the slot
const cMiStallMs = 8000'u64    ## hard ceiling on the borrow (rule 4, in time)
const cMiMaxMods = 32          ## bounds the parse; NOT a silent cap -- see below
const cMiMaxSettings = 64      ## per mod, same

type
  MiPhase = enum
    miIdle                     ## never armed; the MODS tab has not been opened
    miArmed                    ## slot borrowed, waiting for a body
    miDone                     ## parsed and registered; never runs again
    miFailed                   ## refused; never runs again

var gMiPhase = miIdle
var gMiArmedAt = 0'u64
var gMiArmedAttempts = 0'i32
var gMiPages = 0
var gMiRows = 0
var gMiDeclined = 0
var gMiDeclinedFirst = ""
var gMiTruncated = 0

proc miRelease() =
  ## Give the shared slot back to whatever the host was polling. Called on
  ## EVERY exit path -- a borrow that is not returned blinds live mod control
  ## for the rest of the session, which is a measured consequence and not a
  ## theoretical one.
  if gSyncPath.len > 0 and gSyncMs > 0:
    overlaySyncStart(gSyncPath, int32(gSyncMs))

proc miFail(why: string) =
  gMiPhase = miFailed
  miRelease()
  warn "mods index: " & why & ". The MODS tab shows the host's own pages only " &
       "and no mod page is registered. NOTHING was hidden and nothing was " &
       "written, so this refusal costs the player nothing."

proc miKindOf(ty: string; row: var SwRow): bool =
  ## Map the route's declared type onto a row kind this host can actually draw.
  ## Returns false when there is no native control for it.
  ##
  ## THE DECLINE IS THE POINT. A `choice` needs a `SettingDropDown`, and every
  ## dropdown bind on this build is a GENERIC method with no entry in
  ## `methodPointers`: `BindTo`, `BindToEnum`, `BindDropDownToSetting`,
  ## `UpdateDropDownValue`, and all three `SettingSelectSlider.BindIndexTo`
  ## overloads. `il2cpp_resolve.py genericmethods` can now reach instantiations
  ## offline, but `SettingDropDown::BindTo<int>` comes back sharedness UNKNOWN
  ## -- and unknown is a REFUSAL, not "probably fine".
  ##
  ## So a choice row is drawn as a labelled stub and marked not-wired. It is
  ## NOT faked out of a toggle: a control that renders, moves and silently does
  ## nothing is this repository's most-repeated defect.
  ##
  ## NOTE ON `swkChoice`: a new `SwKind` value was considered and NOT added.
  ## `swkStub` already means exactly "drawn, labelled, bound to nothing", which
  ## is the required behaviour, and adding an enum case would have to be
  ## handled in every `SwKind` switch in `settingspages.nim` -- a file this
  ## change does not otherwise touch. The reason travels on the row's own label
  ## instead, where the player can read it.
  result = true
  if ty == "bool":
    row.kind = swkToggle
    row.implemented = true
  elif ty == "float" or ty == "int":
    row.kind = swkSlider
    row.implemented = true
  else:
    row.kind = swkStub
    row.implemented = false
    result = false

proc miParseSetting(item: string; row: var SwRow): bool =
  result = false
  var key = ""
  var label = ""
  var ty = ""
  if not pathGet(item, "key", key):
    return
  if key.len == 0:
    return
  discard pathGet(item, "label", label)
  discard pathGet(item, "type", ty)
  row = SwRow()
  row.key = key
  row.label = (if label.len > 0: label else: key)
  var grp = ""
  discard pathGet(item, "group", grp)
  row.category = grp
  let drawable = miKindOf(ty, row)
  if not drawable:
    gMiDeclined = gMiDeclined + 1
    if gMiDeclinedFirst.len == 0:
      gMiDeclinedFirst = key & " (type '" & ty & "')"
    row.label = row.label & "  [" & ty & " - no native control]"
  var cur = ""
  if pathGet(item, "current", cur):
    if row.kind == swkToggle:
      row.bval = (cur == "1" or cur == "true")
    elif row.kind == swkSlider:
      row.fval = modSetParseF64(cur, 0.0)
  var lo = ""
  var hi = ""
  if pathGet(item, "min", lo):
    row.lo = modSetParseF64(lo, 0.0)
  if pathGet(item, "max", hi):
    row.hi = modSetParseF64(hi, 1.0)
  result = true

proc miGroupRows(rows: seq[SwRow]): seq[SwRow] =
  ## Sub-grouping, and ONLY when the schema asks for it. A mod whose settings
  ## declare no `group` gets a flat page with no invented headings; a mod that
  ## does gets one stub heading per group, in first-seen order, with its
  ## settings under it. That is the "sub-sub-tabs only for mods whose schema
  ## declares groups" rule, expressed as headings rather than as another tab
  ## level -- the strip machinery is already two levels deep and a third would
  ## need its own donor, its own exclusivity and its own verdict.
  result = @[]
  var anyGroup = false
  var i = 0
  while i < rows.len:
    if rows[i].category.len > 0:
      anyGroup = true
      break
    i = i + 1
  if not anyGroup:
    i = 0
    while i < rows.len and result.len < cSwMaxRows:
      result.add rows[i]
      i = i + 1
    return
  var cats: seq[string] = @[]
  i = 0
  while i < rows.len:
    let c = rows[i].category
    if c.len > 0:
      var seen = false
      var k = 0
      while k < cats.len:
        if cats[k] == c:
          seen = true
          break
        k = k + 1
      if not seen:
        cats.add c
    i = i + 1
  var ci = 0
  while ci < cats.len and result.len < cSwMaxRows:
    var head = SwRow()
    head.kind = swkStub
    head.implemented = true
    head.label = "-- " & cats[ci] & " --"
    head.key = ""
    head.category = cats[ci]
    result.add head
    var j = 0
    while j < rows.len and result.len < cSwMaxRows:
      if rows[j].category == cats[ci]:
        result.add rows[j]
      j = j + 1
    ci = ci + 1
  # Ungrouped settings last, so a partially-grouped schema loses nothing.
  var u = 0
  while u < rows.len and result.len < cSwMaxRows:
    if rows[u].category.len == 0:
      result.add rows[u]
    u = u + 1

proc miParse(doc: string): bool =
  ## `{"mods":[{guid,name,settings:[...]}, ...]}` -- the documented shape of
  ## `/aowlspt/settings/index`. Built against the documented shape on purpose,
  ## and it must fail CLEANLY on a body that is not it rather than register
  ## half a tab.
  result = false
  var mods: seq[string] = @[]
  if not pathItems(doc, "mods", mods):
    miFail("the settings index did not parse as a mods array (" & $doc.len &
           " byte(s) received). This is built against the documented shape of " &
           "/aowlspt/settings/index, so the body is either an older route or " &
           "an error page")
    return
  var m = 0
  while m < mods.len and m < cMiMaxMods:
    var guid = ""
    var name = ""
    discard pathGet(mods[m], "guid", guid)
    discard pathGet(mods[m], "name", name)
    if guid.len == 0:
      m = m + 1
      continue
    var items: seq[string] = @[]
    discard pathItems(mods[m], "settings", items)
    var raw: seq[SwRow] = @[]
    var i = 0
    while i < items.len and i < cMiMaxSettings:
      var row = SwRow()
      if miParseSetting(items[i], row):
        raw.add row
      i = i + 1
    if items.len > cMiMaxSettings:
      gMiTruncated = gMiTruncated + 1
    var page = SwPage(id: "mod:" & guid,
                      title: (if name.len > 0: name else: guid),
                      modGuid: guid, stub: false, note: "",
                      renderedFor: 0'u64)
    page.rows = miGroupRows(raw)
    swPageRegister(page)
    gMiPages = gMiPages + 1
    gMiRows = gMiRows + page.rows.len
    m = m + 1
  if mods.len > cMiMaxMods:
    warn "mods index: the route named " & $mods.len & " mod(s) and this host " &
         "parses at most " & $cMiMaxMods & ", so " & $(mods.len - cMiMaxMods) &
         " were NOT registered. Said out loud rather than dropped silently."
  result = gMiPages > 0

proc miArm(now: uint64) =
  ## Borrow the slot and ask for the index. Called ONCE, from the first MODS
  ## tab open -- never at boot, which is the crash this path exists to avoid.
  if gMiPhase != miIdle:
    return
  if gSyncMs <= 0:
    miFail("no backend is configured, so there is no settings index to fetch")
    return
  gMiPhase = miArmed
  gMiArmedAt = now
  gMiArmedAttempts = overlaySyncAttempts()
  overlaySyncStart("/aowlspt/settings/index", int32(cMiPollMs))
  okLog "mods index: the MODS tab was opened for the first time, so the " &
        "settings index is being fetched NOW -- once, lazily, on the " &
        "overlay's worker thread. Deliberately NOT the boot-time per-mod " &
        "fetch that crashes at character-select: this is ONE request for " &
        "every mod and every setting, cached for the session. Borrow ceiling " &
        $cMiStallMs & "ms, after which the shared sync slot goes back to live " &
        "mod control whatever has arrived."

proc miTick(now: uint64) =
  ## One bounded step per host tick while armed. Before the first open and
  ## after the fetch completes this is a single enum test.
  if gMiPhase != miArmed:
    return
  let doc = overlaySyncTake()
  if doc.len == 0:
    if now - gMiArmedAt > cMiStallMs:
      let attempts = overlaySyncAttempts() - gMiArmedAttempts
      if attempts <= 0'i32:
        miFail("settings index route not served -- the worker never issued a " &
               "request for /aowlspt/settings/index within " & $cMiStallMs &
               "ms (attempts-since-arm=0), which is a slot-changeover problem " &
               "rather than a missing route")
      else:
        miFail("settings index route not served -- the worker issued " &
               $attempts & " request(s) for /aowlspt/settings/index and none " &
               "returned a body here. Either the route is not implemented yet " &
               "or something else consumed the slot's take cursor first")
    return
  gMiPhase = miDone
  miRelease()
  if miParse(doc):
    okLog "mods index: registered " & $gMiPages & " mod page(s) holding " &
          $gMiRows & " row(s) from ONE fetch of /aowlspt/settings/index (" &
          $doc.len & " byte(s)), cached for the session -- no per-mod round " &
          "trip and nothing at boot. " & $gMiDeclined & " setting(s) are drawn " &
          "as labelled stubs because this host has no native control for " &
          "their type" &
          (if gMiDeclinedFirst.len > 0: ", first " & gMiDeclinedFirst else: "") &
          ". The shared sync slot has been handed back to live mod control."
    if gMiTruncated > 0:
      warn "mods index: " & $gMiTruncated & " mod(s) declared more settings " &
           "than this host parses per page, so those pages are INCOMPLETE. " &
           "Reported rather than silently truncated."
  else:
    if gMiPhase == miDone:
      miFail("the settings index parsed but named no mod with a guid")

# ===========================================================================
# STEP 4 -- THE KEYBIND INDEX (`/aowlspt/keybinds`).
#
# Same shape, same transport and the same borrow discipline as the settings
# index above, for the same reasons: armed ONCE on a show edge, never at boot,
# answered on the overlay's worker thread, and the shared sync slot handed
# back on every exit path. `takeModSet` is blind while we hold it, and that
# once delayed a mod unload into the character-select transition.
#
# DISPLAY ONLY. This fetches what the binds ARE; nothing here rebinds
# anything, and the rows built from it are deliberately inert. Said in the log
# too, because a keybind row that looks clickable and silently does nothing is
# exactly the defect this project keeps producing.
# ===========================================================================

const cKbMaxBinds = 128           ## rule 4: bounds the parse and the rows

type
  KbBind = object
    ## One RENDERED ROW. Headings are rows too: the route groups binds under
    ## mods, and a flat list would lose which mod owns which action.
    modName*: string
    action*: string
    key*: string
    heading*: bool          ## a mod name, drawn as a row with no key
    unbound*: bool          ## the route served no `value` for this bind

var gKbPhase = miIdle
var gKbArmedAt = 0'u64
var gKbArmedAttempts = 0'i32
var gKbBinds: seq[KbBind] = @[]
var gKbTruncated = 0

proc kbCount*(): int = gKbBinds.len
proc kbReady*(): bool = gKbPhase == miDone
proc kbFailed*(): bool = gKbPhase == miFailed

proc kbFail(why: string) =
  gKbPhase = miFailed
  miRelease()
  warn "keybinds: " & why & ". The CONTROLS>MODS page lists nothing; the " &
       "stock Controls pages are untouched and nothing was written."

proc kbIsSwitch(v: string): bool =
  ## `true`/`false` are ENABLE SWITCHES, not binds. `aowl.maps hotkeys` and
  ## `aowl.fovfix holdToZoom` both arrive in the keybind list with boolean
  ## values; rendering them in a KEY column would put the word 'true' where a
  ## player expects a key. They are skipped and named in the log rather than
  ## shown, because a keybind page that lists a non-key is lying about what it
  ## is a page of.
  v == "true" or v == "false"

proc kbAllDigits(v: string): bool =
  if v.len == 0: return false
  var i = 0
  while i < v.len:
    if v[i] < '0' or v[i] > '9': return false
    i = i + 1
  true

proc kbKeyLabel(val: string): string =
  ## Render a served value as something a player can read.
  ##
  ## A bare ORDINAL is a `UnityEngine.KeyCode` number (measured: `aowl.debug
  ## overlayToggleKey value=114`, and 114 is KeyCode.R). It is resolved
  ## through the table generated from the client's own metadata; an ordinal
  ## this build does not declare shows as `KeyCode <n>` so an unknown number
  ## reads as an unknown number rather than as a wrong key.
  if not kbAllDigits(val):
    return val
  var n = 0
  var i = 0
  while i < val.len and i < 9:
    n = n * 10 + (int(val[i]) - int('0'))
    i = i + 1
  let nm = ntKeyCodeName(int32(n))
  if nm.len > 0: nm else: "KeyCode " & val

proc kbParse(doc: string): bool =
  ## THE REAL SHAPE, measured off the wire rather than assumed:
  ##
  ##   {"mods":[{"guid":..,"name":..,"client":..,
  ##             "keybinds":[{"key":..,"settingKey":..,"action":..,
  ##                          "description":..,"value":..,"default":..}]}]}
  ##
  ## The first version of this parser was written against `{"binds":[...]}`,
  ## which the route never served. It would have refused cleanly rather than
  ## rendering nonsense -- but it would still have been wrong, and the honest
  ## record is that the shape came from a measurement, not from my guess.
  ##
  ## `key` IS NOT THE BOUND KEY. It is the SETTING key (e.g. `zoomToggleKey`).
  ## The bound KeyCode is `value`, which the backend is adding now -- so a
  ## missing `value` is EXPECTED today and is rendered as unbound rather than
  ## as a blank, and never as the setting key pretending to be a key.
  result = false
  var mods: seq[string] = @[]
  if not pathItems(doc, "mods", mods):
    kbFail("the keybind index has no `mods` array (" & $doc.len &
           " byte(s) received). That is the field this parser needs and the " &
           "one it could not find -- either an older route or an error body")
    return
  gKbBinds = @[]
  var missingValue = 0
  var skipped = 0
  var skippedNames = ""
  var modsWithBinds = 0
  var m = 0
  while m < mods.len and m < cKbMaxBinds:
    var name = ""
    var guid = ""
    discard pathGet(mods[m], "name", name)
    discard pathGet(mods[m], "guid", guid)
    var items: seq[string] = @[]
    discard pathItems(mods[m], "keybinds", items)
    # A MOD WITH NO BINDS IS NOT AN ERROR. Most mods have none; listing them
    # as empty headings would bury the ones that do.
    if items.len == 0:
      m = m + 1
      continue
    modsWithBinds = modsWithBinds + 1
    if gKbBinds.len < cKbMaxBinds:
      gKbBinds.add KbBind(modName: (if name.len > 0: name else: guid),
                          action: (if name.len > 0: name else: guid),
                          key: "", heading: true, unbound: false)
    var i = 0
    while i < items.len and gKbBinds.len < cKbMaxBinds:
      var act = ""
      var setKey = ""
      var val = ""
      discard pathGet(items[i], "action", act)
      discard pathGet(items[i], "settingKey", setKey)
      if setKey.len == 0: discard pathGet(items[i], "key", setKey)
      var err = ""
      var dflt = ""
      discard pathGet(items[i], "default", dflt)
      discard pathGet(items[i], "error", err)
      # `pathGet` RETURNS THE LITERAL TEXT `null` FOR A JSON NULL, so a bare
      # `val.len > 0` is true for `"value":null` and the page would print the
      # word "null" as the bound key. That is a confidently wrong answer in the
      # one column the player actually reads, so it is guarded explicitly
      # rather than left to the length test.
      var haveVal = pathGet(items[i], "value", val)
      if haveVal and (val.len == 0 or val == "null"):
        haveVal = false
      if not haveVal: missingValue = missingValue + 1
      # SKIP ENABLE SWITCHES. Named in the log so 'my mod's toggle is missing'
      # has an answer that is not a shrug.
      if kbIsSwitch(val) or kbIsSwitch(dflt):
        skipped = skipped + 1
        if skippedNames.len < 200:
          skippedNames = skippedNames & (if skippedNames.len > 0: ", " else: "") &
                         (if name.len > 0: name else: guid) & "." & setKey
        i = i + 1
        continue
      if act.len > 0 or setKey.len > 0:
        gKbBinds.add KbBind(
          modName: (if name.len > 0: name else: guid),
          action: (if act.len > 0: act else: setKey),
          # THREE DIFFERENT REASONS FOR NO KEY, and they are not the same
          # thing to a player: the route could not resolve the setting at all
          # (`error`), the mod declares a default but nothing is bound, or the
          # bind is legitimately empty. Only the first is a fault.
          key: (if haveVal: kbKeyLabel(val)
                elif err.len > 0 and err != "null": setKey & " (" & err & ")"
                elif dflt.len > 0 and dflt != "null":
                  setKey & " (unbound, default " & kbKeyLabel(dflt) & ")"
                else: setKey & " (unbound)"),
          heading: false, unbound: not haveVal)
      i = i + 1
    m = m + 1
  if gKbBinds.len >= cKbMaxBinds:
    gKbTruncated = 1
    warn "keybinds: the row cap of " & $cKbMaxBinds & " was reached, so some " &
         "binds are NOT listed. Reported rather than silently dropped."
  if missingValue > 0:
    warn "keybinds: " & $missingValue & " bind(s) arrived with no `value` " &
         "field, so their key column shows the SETTING key marked " &
         "(unbound) rather than a KeyCode. `value` is the field that carries " &
         "the actual bind; a JSON null there is reported as unbound rather " &
         "than printed as the word null, which is what a bare length test " &
         "would have done."
  if gKbBinds.len == 0:
    kbFail("the keybind index parsed and " & $mods.len & " mod(s) were " &
           "listed, but NONE declared a non-empty `keybinds` array, so there " &
           "is nothing to show")
    return
  if skipped > 0:
    okLog "keybinds: skipped " & $skipped & " entry/entries whose value is " &
          "true/false -- they are ENABLE SWITCHES, not binds, and a key " &
          "column showing the word 'true' would misrepresent the page: " &
          skippedNames
  okLog "keybinds: parsed " & $modsWithBinds & " mod(s) with binds out of " &
        $mods.len & " served, giving " & $gKbBinds.len & " row(s) " &
        "(headings included). Mods with no keybinds are skipped rather than " &
        "listed as empty headings."
  result = true
proc kbArm*(now: uint64) =
  ## Armed on the CONTROLS>MODS subtab's show edge, once per session.
  if gKbPhase != miIdle: return
  if gSyncMs <= 0:
    kbFail("no backend is configured, so there are no keybinds to fetch")
    return
  gKbPhase = miArmed
  gKbArmedAt = now
  gKbArmedAttempts = overlaySyncAttempts()
  overlaySyncStart("/aowlspt/keybinds", int32(cMiPollMs))
  okLog "keybinds: the CONTROLS>MODS page was opened for the first time, so " &
        "/aowlspt/keybinds is being fetched NOW -- once, lazily, on the " &
        "overlay's worker thread, and cached for the session. DISPLAY ONLY: " &
        "this pass lists the binds and does not rebind anything."

proc kbTick*(now: uint64) =
  if gKbPhase != miArmed: return
  let doc = overlaySyncTake()
  if doc.len == 0:
    if now - gKbArmedAt > cMiStallMs:
      let attempts = overlaySyncAttempts() - gKbArmedAttempts
      if attempts <= 0'i32:
        kbFail("keybind route not served -- the worker never issued a request " &
               "for /aowlspt/keybinds within " & $cMiStallMs & "ms")
      else:
        kbFail("keybind route not served -- the worker issued " & $attempts &
               " request(s) and none returned a body here")
    return
  gKbPhase = miDone
  miRelease()
  if kbParse(doc):
    okLog "keybinds: " & $gKbBinds.len & " mod keybind(s) from ONE fetch of " &
          "/aowlspt/keybinds (" & $doc.len & " byte(s)), cached for the " &
          "session. The shared sync slot has been handed back."
  else:
    if gKbPhase == miDone:
      kbFail("the keybind index parsed but named no binds")