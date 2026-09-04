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

## THE ROUTE, MEASURED. `/aowlspt/settings/index` is the COMPACT index: it
## carries `{guid,name,count,done,pageRoute,...}` per mod and NO `settings`
## array at all (`mods/settingshub/settingshub.nim`, `onModsIndex`) -- which is
## exactly what the deployed run reported: 'registered 11 mod page(s) holding 0
## row(s) from ONE fetch of /aowlspt/settings/index (960 byte(s))'. 960 bytes
## for 11 mods is a list of names, not a schema. `/aowlspt/settings/index/full`
## is the SAME list with each mod's full row array embedded (`onIndexFull`),
## which is the one-fetch contract this file was written against; the compact
## route was simply the wrong URL. The lazy-fetch discipline is unchanged and
## is what `onIndexFull`'s own header demands: on the tab opening, never on a
## poll, never at boot.
const cMiRoute = "/aowlspt/settings/index/full"
const cMiPollMs = 250          ## worker re-poll cadence while we hold the slot
const cMiStallMs = 8000'u64    ## hard ceiling on the borrow (rule 4, in time)
const cMiMaxMods = 32          ## bounds the parse; NOT a silent cap -- see below
## PER MOD. MEASURED 2026-09-04 against the live backend (curl, identity):
## the largest schema on this install is `aowl.tarkov` at 949 rows, then
## aowl.maps 61, aowl.sain 55, aowl.graphics 29. At 64 this cap cut the
## biggest mod down to 64 and printed `truncated` for it every session --
## a bound chosen before anything had been measured. 1024 is the measured
## maximum with headroom, and it bounds the PARSE only.
##
## IT IS NOT WHAT LIMITS A PAGE ON SCREEN. `cSwMaxRows` (settingspages.nim,
## 48) bounds how many rows any page RENDERS, because each row instantiates
## Unity objects into a live screen. So a 949-row mod parses whole here and
## still shows 48 rows, and the verdict below says which of the two bounds
## did it rather than reporting one number. Completing such a page needs the
## renderer to instantiate in slices too -- that is settingspages.nim's
## bound, shared with two other consumers, and it is deliberately NOT raised
## from here.
const cMiMaxSettings = 1024
## Rows parsed per host tick. Rule 4 is a cap; this is the cap made small
## enough that the cap itself is not a stall: 11 mods x up to 949 rows in one
## tick is a frame the player sees.
const cMiSliceRows = 32

type
  MiPhase = enum
    miIdle                     ## never armed; the MODS tab has not been opened
    miArmed                    ## slot borrowed, waiting for a body
    miParsing                  ## body in hand, parsed a slice at a time
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
## PER-MOD ROW ACCOUNTING. `count` is what the mod itself declared; `rows` is
## what we actually built. A total is not a check -- one mod with rows hides
## ten with none, which is how a 0-row tab shipped looking healthy. Named,
## bounded, and reported as a FAIL that names the mod.
var gMiShort = ""
var gMiShortN = 0
## RESUMABLE PARSE STATE. The body is held and walked a slice per tick rather
## than in one call; see `miParseSlice`.
var gMiDoc = ""
var gMiModsSeq: seq[string] = @[]
var gMiModAt = 0
var gMiItems: seq[string] = @[]
var gMiHaveItems = false
var gMiRaw: seq[SwRow] = @[]
var gMiRowAt = 0
var gMiGuid = ""
var gMiName = ""
var gMiWant = 0
var gMiInconc = false
## WHAT IT COST THE FRAME, in ms, measured with the host's own clock rather
## than asserted. `gMiWorstMs` is the number that matters: an average hides
## the stall that a player sees, and the whole reason this parse is sliced is
## a 569,247-byte document arriving on the Unity main thread.
var gMiSlices = 0
var gMiParseMs = 0'u64
var gMiWorstMs = 0'u64
var gMiWorstWhat = ""
var gMiTruncatedFirst = ""
var gMiRenderCapped = 0
## THE ENABLED SWITCH, COUNTED. `gMiEnabled` is pages that got one;
## `gMiNoEnable` is pages that deliberately did not, with the first reason
## named. A total of zero used to be indistinguishable from "the feature is
## not wired", which is exactly what the deployed run could not tell anyone.
var gMiEnabled = 0
var gMiNoEnable = 0
var gMiNoEnableFirst = ""

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

proc miUnquote(raw: string): string =
  ## One element of a JSON string array, as its text. `pathItems` is a
  ## SPLITTER, not a decoder -- it hands each element back verbatim, so a
  ## string element still carries its quotes and its escapes. An option
  ## rendered as `"High"` including the quote marks is a caption the player
  ## can see is wrong.
  ##
  ## Deliberately minimal: the four escapes a settings schema can actually
  ## produce, and an UNKNOWN escape keeps its character rather than being
  ## dropped, because losing a character silently is worse than showing a
  ## backslash. Capped at 64 characters -- a dropdown caption longer than that
  ## is clipped by the control anyway.
  result = ""
  var v = strip(raw)
  if v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"':
    v = v.substr(1, v.len - 2)
  var i = 0
  while i < v.len and result.len < 64:
    if v[i] == '\\' and i + 1 < v.len:
      let c = v[i + 1]
      if c == 'n': result.add '\n'
      elif c == 't': result.add '\t'
      elif c == '\"': result.add '\"'
      elif c == '\\': result.add '\\'
      else: result.add c
      i = i + 2
    else:
      result.add v[i]
      i = i + 1

proc miKindOf(ty: string; row: var SwRow): bool =
  ## Map the route's declared type onto a row kind this host can actually draw.
  ## Returns false when there is no native control for it.
  ##
  ## THE DECLINE IS STILL THE POINT -- for the types that have no control.
  ## `string`, `keybind` and anything unrecognised are drawn as labelled stubs
  ## and marked not-wired, and are NOT faked out of a toggle: a control that
  ## renders, moves and silently does nothing is this repository's most-
  ## repeated defect.
  ##
  ## WHAT CHANGED 2026-09-04, and why the paragraph that stood here was wrong.
  ## It argued that a choice can only ever be a stub because every dropdown
  ## BIND (`BindTo`, `BindToEnum`, `BindDropDownToSetting`, the three
  ## `SettingSelectSlider.BindIndexTo` overloads) is a generic whose
  ## instantiation comes back sharedness UNKNOWN. That is all true and it is
  ## also beside the point: NONE of those is needed. `dlssrows.nim` had
  ## already been filling a cloned `SettingDropDown` for months by CALLING the
  ## game's own `BaseDropDownBox::Show` through the receiver's own vtable slot
  ## 24, and repainting the caption through the game's own `SetLabelText`.
  ## MEASURED consequence of the old reading: 62 settings across 11 mods
  ## rendered as captioned stubs on the deployed build 61238a816f58 while a
  ## working mechanism for them sat in the next file.
  result = true
  if ty == "bool":
    row.kind = swkToggle
    row.implemented = true
  elif ty == "float" or ty == "int":
    row.kind = swkSlider
    row.implemented = true
  elif (ty == "enum" or ty == "select") and row.choices.len > 0 and
       row.choices.len <= 16:
    # AN ENUM IS NOW A REAL DROPDOWN, and the long paragraph above -- which
    # concluded a choice row can only ever be a stub -- was answering the
    # wrong question. The generic `BindTo<T>` is not needed and was never the
    # only way in: `dlssrows.nim` fills a cloned `SettingDropDown` by CALLING
    # the game's own `BaseDropDownBox::Show` through the RECEIVER'S OWN vtable
    # slot 24, with all three candidate bodies byte-verified and the interface
    # table pre-checked (`nuDropDownShow`, six proofs), and repaints the
    # caption through the game's own `SetLabelText`. That mechanism is REUSED
    # here, not copied; `settingspages.nim` demotes the row back to a labelled
    # stub, loudly, if any of those proofs refuses on the live control.
    #
    # 1..16 is the bound `nuDropDownShow` itself enforces. A schema offering
    # more options than that is still a stub -- and the decline below names
    # the type, so it is not silent.
    row.kind = swkChoice
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
  # THE FIELD NAMES ARE THE ROUTE'S, NOT A GUESS. `aowl/src/aowlspt/settings.nim`
  # `toJson` emits `category` (and `subcategory`/`path`); it never emits
  # `group`. Reading `group` could only ever produce a flat page, silently.
  # `group` is still accepted as a fallback so an older mod that really does
  # send it is not dropped.
  var grp = ""
  if not pathGet(item, "category", grp):
    discard pathGet(item, "group", grp)
  row.category = grp
  # THE OPTIONS, PARSED BEFORE THE KIND IS DECIDED, because the kind depends on
  # them. `options` carries the values that are PERSISTED; `optionLabels`,
  # when the schema ships exactly as many, carries display names only. Field
  # names are `aowl/src/aowlspt/settings.nim`'s own (`toJson`, lines 405-410),
  # not a guess.
  var opts: seq[string] = @[]
  var labels: seq[string] = @[]
  if pathItems(item, "options", opts):
    discard pathItems(item, "optionLabels", labels)
    var oi = 0
    while oi < opts.len and oi < 16:
      row.choiceVals.add miUnquote(opts[oi])
      if labels.len == opts.len:
        row.choices.add miUnquote(labels[oi])
      else:
        row.choices.add miUnquote(opts[oi])
      oi = oi + 1
  let drawable = miKindOf(ty, row)
  if not drawable:
    gMiDeclined = gMiDeclined + 1
    if gMiDeclinedFirst.len == 0:
      gMiDeclinedFirst = key & " (type '" & ty & "')"
    row.label = row.label & "  [" & ty & " - no native control]"
  # Likewise the current value is `value` -- `toJson` line 400. `current` was
  # never emitted by anything, so every row drew at its zero default and a
  # toggle showed OFF for a setting that is ON. Fallback kept for the same
  # reason as above.
  var cur = ""
  if not pathGet(item, "value", cur):
    discard pathGet(item, "current", cur)
  if cur.len > 0:
    if row.kind == swkToggle:
      row.bval = (cur == "1" or cur == "true")
    elif row.kind == swkSlider:
      row.fval = modSetParseF64(cur, 0.0)
    elif row.kind == swkChoice:
      # THE STORED VALUE IS THE OPTION STRING, so the selection is found by
      # MATCHING it, never by parsing it as a number. A value matching no
      # option leaves the row on option 1 and SAYS so: inventing an index for
      # it would show the player a selection the config does not hold.
      var found = 0
      var ci = 0
      while ci < row.choiceVals.len:
        if row.choiceVals[ci] == cur:
          found = ci + 1
          break
        ci = ci + 1
      if found > 0:
        row.fval = float64(found)
      else:
        row.fval = 1.0
        okLog "mods index: setting '" & key & "' stores '" & cur &
              "', which is NOT one of the " & $row.choiceVals.len &
              " option(s) its own schema declares. The dropdown shows " &
              "option 1; nothing was written, and the stored value stands " &
              "until the player picks one."
  elif row.kind == swkChoice:
    row.fval = 1.0
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

proc miParseBegin(doc: string): bool =
  ## Split the document into its mods ONCE, and do nothing else this tick.
  ## Returns false (and has already failed loudly) when the body is not the
  ## documented shape.
  ##
  ## This is the one unavoidably whole-document step -- 569,247 bytes on the
  ## measured install -- so it is a tick of its own, it is TIMED, and the
  ## timing is reported whether or not anybody asks. Everything after it is
  ## bounded by `cMiSliceRows`.
  result = false
  let t0 = cNowMs()
  gMiDoc = doc
  gMiModsSeq = @[]
  if not pathItems(doc, "mods", gMiModsSeq):
    miFail("the settings index did not parse as a mods array (" & $doc.len &
           " byte(s) received). This is built against the documented shape of " &
           cMiRoute & ", so the body is either an older route or an error page")
    return
  let dt = cNowMs() - t0
  gMiSlices = gMiSlices + 1
  gMiParseMs = gMiParseMs + dt
  if dt > gMiWorstMs:
    gMiWorstMs = dt
    gMiWorstWhat = "the whole-document split into " & $gMiModsSeq.len & " mod(s)"
  gMiModAt = 0
  gMiHaveItems = false
  result = true

proc miFinishParse() =
  ## Everything that used to be said after the single-call parse, said once
  ## the last slice has run.
  gMiPhase = miDone
  if gMiModsSeq.len > cMiMaxMods:
    warn "mods index: the route named " & $gMiModsSeq.len & " mod(s) and " &
         "this host parses at most " & $cMiMaxMods & ", so " &
         $(gMiModsSeq.len - cMiMaxMods) & " were NOT registered. Said out " &
         "loud rather than dropped silently."
  # Let the document go. It is the largest single allocation this host makes
  # and nothing reads it again.
  gMiDoc = ""
  gMiModsSeq = @[]
  gMiItems = @[]
  gMiRaw = @[]

proc miParseSlice() =
  ## ONE BOUNDED STEP. Either the split of one mod's `settings` array, or up
  ## to `cMiSliceRows` rows of it -- never both, and never more.
  let t0 = cNowMs()
  var what = ""
  if gMiModAt >= gMiModsSeq.len or gMiModAt >= cMiMaxMods:
    miFinishParse()
    return
  if not gMiHaveItems:
    gMiGuid = ""
    gMiName = ""
    discard pathGet(gMiModsSeq[gMiModAt], "guid", gMiGuid)
    discard pathGet(gMiModsSeq[gMiModAt], "name", gMiName)
    if gMiGuid.len == 0:
      gMiModAt = gMiModAt + 1
      return
    var declared = ""
    discard pathGet(gMiModsSeq[gMiModAt], "count", declared)
    gMiWant = int(modSetParseF64(declared, 0.0))
    var missing = ""
    gMiInconc = pathGet(gMiModsSeq[gMiModAt], "rowsMissing", missing) and
                (missing == "1" or missing == "true")
    gMiItems = @[]
    discard pathItems(gMiModsSeq[gMiModAt], "settings", gMiItems)
    gMiRaw = @[]
    gMiRowAt = 0
    gMiHaveItems = true
    what = "the settings split of " & gMiGuid & " (" & $gMiItems.len & " row(s))"
  else:
    var n = 0
    while gMiRowAt < gMiItems.len and gMiRowAt < cMiMaxSettings and
          n < cMiSliceRows:
      var row = SwRow()
      if miParseSetting(gMiItems[gMiRowAt], row):
        gMiRaw.add row
      gMiRowAt = gMiRowAt + 1
      n = n + 1
    what = $n & " row(s) of " & gMiGuid
    if gMiRowAt >= gMiItems.len or gMiRowAt >= cMiMaxSettings:
      # THIS MOD IS DONE -- register its page and account for it.
      if gMiItems.len > cMiMaxSettings:
        gMiTruncated = gMiTruncated + 1
        if gMiTruncatedFirst.len == 0:
          gMiTruncatedFirst = gMiGuid & " (" & $gMiItems.len & " declared, " &
                              $cMiMaxSettings & " parsed)"
      var page = SwPage(id: "mod:" & gMiGuid,
                        title: (if gMiName.len > 0: gMiName else: gMiGuid),
                        modGuid: gMiGuid, stub: false, note: "",
                        renderedFor: 0'u64)
      page.rows = miGroupRows(gMiRaw)
      # THE PER-MOD ENABLED SWITCH, THE FIRST ROW OF THE PAGE.
      #
      # MEASURED ABSENCE, deployed build 61238a816f58: not one 'ENABLED row'
      # or 'V3 ENABLE' line in a run with the MODS tab open for two minutes,
      # so no mod could be switched on or off from the tab at all. The reason
      # is structural rather than a bug in the switch: `modSetParseSchema`
      # (modsettingsrender.nim) prepends it, and these pages do not come from
      # there -- they are built HERE, from one fetch of the index, and this
      # was the one place a page could be born without one.
      #
      # Same rule as the other builder, deliberately identical: the state is
      # SEEDED FROM THE MANAGER and never guessed. `overlayModEnabled` answers
      # with four states, two of which are not booleans; when it has no answer
      # for this guid NO ROW IS ADDED and the log says which of the two
      # not-an-answer cases it was. A switch seeded from a guess writes the
      # guess on the next save.
      let ms = overlayModEnabled(gMiGuid)
      if ms == ovModEnabled or ms == ovModDisabled:
        var er = SwRow()
        er.key = "__enabled"
        er.label = "Enabled"
        er.kind = swkToggle
        er.bval = (ms == ovModEnabled)
        er.implemented = true
        er.enableRow = true
        var withEnable: seq[SwRow] = @[er]
        var wi = 0
        while wi < page.rows.len and withEnable.len < cSwMaxRows:
          withEnable.add page.rows[wi]
          wi = wi + 1
        if withEnable.len < page.rows.len + 1:
          warn "mods index: the ENABLED switch for '" & gMiGuid & "' cost " &
               "the last schema row its place -- the page is at the " &
               $cSwMaxRows & "-row cap. The switch is shown and one setting " &
               "is NOT. Raise cSwMaxRows rather than leaving this unsaid."
        page.rows = withEnable
        gMiEnabled = gMiEnabled + 1
      else:
        gMiNoEnable = gMiNoEnable + 1
        if gMiNoEnableFirst.len == 0:
          gMiNoEnableFirst = gMiGuid & " (" &
            (if ms == ovModHostOnly:
               "the mod manager has not answered about this guid -- the row " &
               "this process holds is its own report of what it LOADED, " &
               "which is not the selection"
             else: "the mod manager has no row for it at all") & ")"
      swPageRegister(page)
      gMiPages = gMiPages + 1
      gMiRows = gMiRows + page.rows.len
      # THE CHECK THAT CAN FAIL, and it now separates the two bounds instead
      # of blaming the mod for either. `count` is what the mod declared;
      # `gMiRaw.len` is what we PARSED; `page.rows.len` is what the renderer
      # will accept (`cSwMaxRows`, and grouping adds a heading row per
      # category, so rows >= parsed is normal and is not a discrepancy).
      if gMiWant > 0 and gMiRaw.len < gMiWant:
        if gMiRaw.len >= cMiMaxSettings:
          discard   # already counted as a parse truncation above
        elif gMiShortN < 8:
          gMiShortN = gMiShortN + 1
          gMiShort = gMiShort & (if gMiShort.len > 0: ", " else: "") &
                     (if gMiName.len > 0: gMiName else: gMiGuid) &
                     " declares " & $gMiWant & " and parsed " & $gMiRaw.len &
                     (if gMiInconc: " (the route said rowsMissing -- it could " &
                      "not read that mod's page, so this is INCONCLUSIVE " &
                      "rather than a render failure)" else: "")
      if gMiRaw.len > cSwMaxRows:
        gMiRenderCapped = gMiRenderCapped + 1
      gMiModAt = gMiModAt + 1
      gMiHaveItems = false
  let dt = cNowMs() - t0
  gMiSlices = gMiSlices + 1
  gMiParseMs = gMiParseMs + dt
  if dt > gMiWorstMs:
    gMiWorstMs = dt
    gMiWorstWhat = what

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
  overlaySyncStart(cMiRoute, int32(cMiPollMs))
  okLog "mods index: the MODS tab was opened for the first time, so the " &
        "settings index (" & cMiRoute & ") is being fetched NOW -- once, lazily, on the " &
        "overlay's worker thread. Deliberately NOT the boot-time per-mod " &
        "fetch that crashes at character-select: this is ONE request for " &
        "every mod and every setting, cached for the session. Borrow ceiling " &
        $cMiStallMs & "ms, after which the shared sync slot goes back to live " &
        "mod control whatever has arrived."

proc miParseReport() =
  ## Said ONCE, when the sliced parse finishes. Separated from `miTick` only
  ## so the reporting is not buried inside the state machine.
  if gMiPages > 0:
    okLog "mods index: registered " & $gMiPages & " mod page(s) holding " &
          $gMiRows & " row(s) from ONE fetch of " & cMiRoute &
          ", cached for the session -- no per-mod round trip and nothing at " &
          "boot. " & $gMiDeclined & " setting(s) are drawn as labelled stubs " &
          "because this host has no native control for their type" &
          (if gMiDeclinedFirst.len > 0: ", first " & gMiDeclinedFirst else: "") &
          "."
    # THE COST, MEASURED, not asserted. One frame at 60fps is 16.7ms; the
    # number that decides whether this parse belongs on the main thread at
    # all is the WORST slice, not the total.
    okLog "mods index PARSE COST: " & $gMiParseMs & "ms over " & $gMiSlices &
          " tick(s), worst single tick " & $gMiWorstMs & "ms (" & gMiWorstWhat &
          "). A tick over ~16ms is a frame the player sees, and the fix for " &
          "that is to parse on the overlay worker and hand this thread a " &
          "built table -- stated here so the decision is made against a " &
          "number rather than a feeling."
    if gMiEnabled > 0:
      okLog "mods index ENABLE ROW: " & $gMiEnabled & " of " &
            $gMiPages & " page(s) carry a per-mod ENABLED switch as their " &
            "FIRST row, seeded from the mod manager's own state and bound " &
            "through sbdRegisterEnable, whose edit goes out as " &
            "POST /aowlspt/mods/toggle/<guid> -- the same gesture F12 " &
            "queues. The V3 ENABLE verdict reads the manager's answer back; " &
            "until it lands a switch is INCONCLUSIVE, not a pass." &
            (if gMiNoEnable > 0: " " & $gMiNoEnable & " page(s) got NO " &
               "switch, first: " & gMiNoEnableFirst & "." else: "")
    else:
      warn "mods index ENABLE ROW FAIL: NOT ONE of the " & $gMiPages &
           " page(s) carries a per-mod ENABLED switch, so no mod can be " &
           "switched on or off from this tab" &
           (if gMiNoEnableFirst.len > 0: " -- first reason: " &
              gMiNoEnableFirst else: "") &
           ". This is the deployed build's measured defect, stated as a " &
           "check that can fail rather than as silence."
    if gMiShort.len > 0:
      warn "mods index ROW VERDICT FAIL: " & $gMiShortN & " mod(s) parsed " &
           "fewer rows than they declare -- " & gMiShort &
           ". A mod page showing fewer controls than its schema is the " &
           "player-visible defect; named here rather than hidden inside the " &
           "total of " & $gMiRows & "."
    else:
      okLog "mods index ROW VERDICT PASS: every mod parsed at least as many " &
            "rows as its own `count` declares (" & $gMiRows & " row(s) over " &
            $gMiPages & " page(s)). Compared against the route's `count`, " &
            "not against this host's own parse."
    if gMiTruncated > 0:
      warn "mods index: " & $gMiTruncated & " mod(s) declared more than " &
           $cMiMaxSettings & " settings, this host's PARSE cap, so those " &
           "pages are incomplete" &
           (if gMiTruncatedFirst.len > 0: " -- first " & gMiTruncatedFirst
            else: "") & ". Reported rather than silently truncated."
    if gMiRenderCapped > 0:
      warn "mods index: " & $gMiRenderCapped & " mod(s) parsed MORE rows " &
           "than cSwMaxRows (" & $cSwMaxRows & "), which is what the RENDERER " &
           "accepts, so those pages show the first " & $cSwMaxRows & " rows " &
           "and no more. This is a DIFFERENT bound from the parse cap above " &
           "and it lives in settingspages.nim, shared with two other " &
           "consumers: raising it lets one page instantiate that many Unity " &
           "objects in a single frame, so it needs a sliced renderer, not a " &
           "bigger number. Named so the page is not read as complete."
  else:
    miFail("the settings index parsed but named no mod with a guid")

proc miTick(now: uint64) =
  ## One bounded step per host tick. Before the first open and after the parse
  ## completes this is a single enum test.
  if gMiPhase == miParsing:
    miParseSlice()
    if gMiPhase == miDone:
      miParseReport()
    return
  if gMiPhase != miArmed:
    return
  let doc = overlaySyncTake()
  if doc.len == 0:
    if now - gMiArmedAt > cMiStallMs:
      let attempts = overlaySyncAttempts() - gMiArmedAttempts
      if attempts <= 0'i32:
        miFail("settings index route not served -- the worker never issued a " &
               "request for " & cMiRoute & " within " & $cMiStallMs &
               "ms (attempts-since-arm=0), which is a slot-changeover problem " &
               "rather than a missing route")
      else:
        # THE THIRD OUTCOME, and it is the one that actually happened.
        # The overlay worker REFUSES a body it cannot publish, and until
        # 2026-09-04 it refused in silence -- so a 569,247-byte answer to
        # a route that works perfectly read as "not implemented yet".
        # Ask the transport what it threw away before blaming the far end.
        var dropLen: int32 = 0
        var dropZlib = false
        let drops = overlaySyncDrops(dropLen, dropZlib)
        if drops > 0:
          miFail("settings index NOT DELIVERED BY THE TRANSPORT -- the " &
                 "worker issued " & $attempts & " request(s) for " & cMiRoute &
                 " and the overlay feed REFUSED " & $drops & " body(ies), the " &
                 "last of them " & $dropLen & " byte(s)" &
                 (if dropZlib: " and zlib-deflated (Accept-Encoding: " &
                  "identity was not honoured by the backend)" else:
                  " (too large for the publish bound)") &
                 ". The ROUTE ANSWERED; this is a transport bound, not a " &
                 "missing route")
        else:
          miFail("settings index route not served -- the worker issued " &
                 $attempts & " request(s) for " & cMiRoute & " and none " &
                 "returned a body here, and the feed refused none either. " &
                 "Either the route is not implemented yet or something " &
                 "else consumed the slot's take cursor first")
    return
  # THE BODY IS IN HAND. Hand the slot back at once -- the parse does not
  # need it and live mod control does -- then walk the document a slice per
  # tick from `miTick` above.
  miRelease()
  if not miParseBegin(doc):
    return
  gMiPhase = miParsing
  okLog "mods index: a " & $doc.len & " byte body arrived from " & cMiRoute &
        " naming " & $gMiModsSeq.len & " mod(s). Parsing it " &
        $cMiSliceRows & " row(s) per tick rather than in one call: the whole " &
        "document is bigger than anything this host has parsed on the Unity " &
        "main thread before, and the split alone took " & $gMiWorstMs &
        "ms. The shared sync slot has ALREADY been handed back to live mod " &
        "control -- the parse does not need it."

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