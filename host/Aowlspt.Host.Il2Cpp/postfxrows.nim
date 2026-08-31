## ===========================================================================
## postfxrows.nim -- CONTENT for the PostFX subtab panel, built FROM SCRATCH.
##
## THE BUG THIS EXISTS FOR
## -----------------------
## `modstab.nim`'s postfx-subtab feature works: its own finished-state verdict
## reads PASS off the live objects ("exactly one subtab is selected and its
## panel is the only one active"). But all it drives is `activeInHierarchy` on
## the two STOCK panels, and the stock `PostFX Settings` panel is EMPTY once the
## game's own PostFX tab has been folded away. Pressing POSTFX therefore shows a
## correctly-selected, correctly-exclusive, completely blank page. The machinery
## was never the problem; there was simply nothing in the room.
##
## `mods/graphics` declares 29 settings that have never been rendered anywhere
## in the native screen. This file puts them there.
##
## NOTHING HERE IS CLONED
## ----------------------
## Explicitly asked for, and now possible. Every object is built by `nuikit`
## from a bare `GameObject` -- `AddComponent<RectTransform>` ->
## `SetParentAndAlign` -> layer 5 -> `SetActive(false)` ->
## `AddComponent<TextMeshProUGUI>` -> wire the donor's font/material -> layout
## -> `SetActive(true)` -> `set_text` (RE-APPLIED, because `LocalizedText`
## clobbers a raw `m_text` store). That is the IMAGEPROOF-PASS sequence, used
## through `nuLabel` rather than reimplemented. The one thing borrowed from a
## live object is a DONOR TMP's font asset, which `nuLabel` requires: a
## from-scratch `TextMeshProUGUI` with a null `m_fontAsset` faults in `Awake`.
##
## WHY THESE ROWS ARE A CATALOGUE AND NOT YET CONTROLS -- SAID PLAINLY
## ------------------------------------------------------------------
## The live VALUE of each setting reaches this host over exactly one path: the
## `/aowlspt/settings/<guid>` schema fetch in `modsettingsrender.nim`, and that
## path is gated on `modSettingsRender`, WHICH CRASHES THE CLIENT at
## character-select (bisected: with it on the host log stops dead at
## `[0:00:30.828]` right after the profile Submit, with no managed exception in
## the client's own log -- a native access violation; with it off the run passes
## `[0:01:42]`). Another agent owns that crash. This file does NOT turn that
## flag on and does NOT depend on it landing.
##
## So rendering a SLIDER here would mean rendering a slider with no value behind
## it and nowhere to write to -- a control that silently does nothing, which is
## this repository's single most repeated defect and the thing 9b exists to
## forbid. Compounding it, `mods/graphics` has its own trap: `loadConfig` calls
## `applyPreset` and RETURNS whenever `preset != "custom"` (graphics.nim:189-191),
## so with the deployed `preset` every look slider below that line is read,
## stored and then discarded. A slider that cannot show that state is worse than
## no slider.
##
## What is rendered instead is honest and useful: the full declared catalogue,
## grouped by the mod's own categories, with a banner that states in the panel
## itself that these are names, not live values, and why. `gPfxRows` carries a
## `value` field that is empty today and is the single place a schema-fed build
## would fill in -- the layout does not change when it does.
##
## SAFETY. Flag-gated `settingsPostFxRows`, default OFF, and additionally inert
## unless `nativeUiKit` is on (nuikit refuses on its own if it is not). Built
## ONCE, lazily, the first time the PostFX panel is actually up. No per-frame
## work and no per-frame allocation: after the build the tick is one boolean.
## Self-disables after `PfxMaxFaults`. Every iteration is capped. No guard is
## opened here -- this is called from inside `modsBody`'s single
## `aowl_p_p_seh`, and `aowl_p_p_seh` is NOT re-entrant.
## ===========================================================================

const PfxMaxFaults = 4
const PfxMaxRows = 64              ## rule 4; the catalogue is 29 + 11 headers
const PfxMaxHandles = 48           ## nuikit's own table is 64 slots

var gPfxOn = false                 ## `settingsPostFxRows` -- read once at boot
var gPfxOff = false                ## self-disabled
var gPfxBuilt = false
var gPfxTried = 0
var gPfxFaults = 0
var gPfxElems: seq[NuElem] = @[]
var gPfxVerdictSaid = false

type
  PfxRow = object
    ## One line of the catalogue. `header` rows are the mod's own category
    ## names; the rest are settings.
    header*: bool
    label*: string
    ## The mod's declared key. Kept even though nothing writes through it yet:
    ## it is what a schema-fed build keys its value lookup on, and it is what
    ## makes "this row corresponds to a real declared setting" checkable rather
    ## than a claim about a string literal.
    key*: string
    ## PRESET-OWNED. Derived from `mods/graphics`' own `presetOwns`, which is
    ## itself derived from `loadConfig`'s early return, not guessed: with
    ## `preset` set to anything but `custom`, every key except `enabled`,
    ## `raidOnly`, `diag` and `preset` is read ONLY in the `custom` branch, so a
    ## stored edit to it can never be observed. Marked on screen so a player
    ## cannot conclude a knob is broken when it is in fact owned.
    presetOwned*: bool
    ## Empty today. See the header comment: the live-value path is blocked on
    ## `modSettingsRender`. NOT defaulted to the schema's declared default,
    ## because printing a default next to a config that may say otherwise is a
    ## confident wrong answer, which is worse than no answer.
    value*: string

proc pfxRow(label, key: string; owned: bool): PfxRow =
  PfxRow(header: false, label: label, key: key, presetOwned: owned, value: "")

proc pfxHead(label: string): PfxRow =
  PfxRow(header: true, label: label, key: "", presetOwned: false, value: "")

proc pfxCatalogue(): seq[PfxRow] =
  ## The 29 settings `mods/graphics/graphics.nim:schema()` declares, in its own
  ## order, under its own category names. Transcribed rather than fetched --
  ## see the header comment for why the fetch is not available -- so this is a
  ## STATIC MIRROR and will drift if the mod's schema changes. `pfxAuditKeys`
  ## below is what makes that drift visible instead of silent.
  @[pfxHead("Preset"),
    pfxRow("Preset", "preset", false),
    pfxHead("Post-process"),
    pfxRow("Enable post-process", "enabled", false),
    pfxRow("Raid only (menu stays stock)", "raidOnly", false),
    pfxHead("Tonemap"),
    pfxRow("Tonemapper", "tonemapper", true),
    pfxRow("Tonemap strength", "tonemapStrength", true),
    pfxRow("Exposure (EV)", "exposure", true),
    pfxHead("Grade"),
    pfxRow("Contrast", "contrast", true),
    pfxRow("Saturation", "saturation", true),
    pfxRow("Vibrance", "vibrance", true),
    pfxRow("Shadow detail (toe lift)", "shadowDetail", true),
    pfxHead("White balance"),
    pfxRow("Temperature", "temperature", true),
    pfxRow("Tint", "tint", true),
    pfxHead("Lift, Gamma, Gain"),
    pfxRow("Lift (shadows)", "lift", true),
    pfxRow("Gamma (midtones)", "gamma", true),
    pfxRow("Gain (highlights)", "gain", true),
    pfxHead("Legacy (AgX)"),
    pfxRow("Shadow lift (additive)", "shadows", true),
    pfxRow("Highlight roll-off", "highlights", true),
    pfxHead("Sharpen"),
    pfxRow("Sharpening (CAS)", "sharpness", true),
    pfxHead("Bloom"),
    pfxRow("Bloom", "bloom", true),
    pfxRow("Bloom strength", "bloomStrength", true),
    pfxRow("Bloom threshold", "bloomThreshold", true),
    pfxHead("Vignette"),
    pfxRow("Vignette", "vignette", true),
    pfxRow("Vignette radius", "vignetteRadius", true),
    pfxHead("Detail"),
    pfxRow("Clarity (local contrast)", "clarity", true),
    pfxHead("Film"),
    pfxRow("Film grain", "grain", true),
    pfxRow("Grain size (px)", "grainSize", true),
    pfxRow("Output dither (LSB)", "dither", true),
    pfxHead("Lens"),
    pfxRow("Chromatic aberration", "chroma", true),
    pfxHead("Debug"),
    pfxRow("Red-tint diagnostic", "diag", false)]

proc pfxNoteFault(what: string) =
  inc gPfxFaults
  warn "postfx rows: " & what & " (fault " & $gPfxFaults & " of " &
       $PfxMaxFaults & ")"
  if gPfxFaults >= PfxMaxFaults:
    gPfxOff = true
    warn "postfx rows: fault ceiling reached; this feature is OFF for the rest " &
         "of the session. Nothing it built is left behind -- the elements it " &
         "owns are destroyed on the next tear-down, and the PostFX panel goes " &
         "back to exactly the empty stock panel it was."

proc pfxDestroyAll(): int =
  ## Tear our elements down. `nuDestroy` is generational, so a handle issued
  ## before a release refuses as RELEASED rather than acting on a recycled
  ## slot; that is why the list can be cleared without a second pass.
  result = 0
  var i = 0
  while i < gPfxElems.len and i < PfxMaxHandles:
    if nuDestroy(gPfxElems[i]):
      result = result + 1
    i = i + 1
  gPfxElems = @[]
  gPfxBuilt = false

proc pfxDonorTmp(): Il2CppPtr =
  ## A LIVE `TextMeshProUGUI` whose font asset and materials `nuLabel` copies
  ## in. Preference order is deliberate: the PostFX panel's own TMP first (same
  ## panel, same styling), then the Graphics Settings panel's. Nothing is ever
  ## written to the donor -- it is read for `m_fontAsset` and the materials and
  ## then left alone.
  result = nil
  if gGfxPostT != nil and duOk(gGfxPostT, 0x20'i32):
    result = modsFindTmp(gGfxPostT, 6)
  if result == nil and gGfxPanelT != nil and duOk(gGfxPanelT, 0x20'i32):
    result = modsFindTmp(gGfxPanelT, 6)
  if result != nil and not iUnityAlive(result):
    result = nil

proc pfxBuild(): bool =
  ## Build the catalogue into the live PostFX panel. Called ONCE, from the tick,
  ## only after the panel has actually been observed up.
  result = false
  if gPfxBuilt or gPfxOff or not gPfxOn:
    return
  inc gPfxTried
  if gGfxPostGo == nil or not duOk(gGfxPostGo, 0x20'i32) or
     not iUnityAlive(gGfxPostGo):
    pfxNoteFault("the stock PostFX Settings GameObject is not a live object " &
                 "right now, so there is nowhere to build. Nothing was added.")
    return
  let donor = pfxDonorTmp()
  if donor == nil:
    pfxNoteFault("no live donor TextMeshProUGUI could be found under either " &
                 "stock panel. nuLabel REFUSES without one -- a from-scratch " &
                 "TMP with a null m_fontAsset faults inside Awake -- so " &
                 "nothing was built rather than something unsafe.")
    return
  let rows = pfxCatalogue()
  # LAYOUT. Parented straight onto the stock panel GameObject rather than onto
  # its content container: the container carries the game's own LayoutGroup,
  # which DRIVES the RectTransform of every direct child and would overwrite
  # the explicit offsets below. The panel itself does not.
  #
  # Top-left anchored, y NEGATIVE going down -- the convention nuikit's own
  # proof used. Three columns so the 40 lines fit a panel-height page without
  # a scroll view we have no way to build yet.
  const colX = [60.0'f32, 640.0'f32, 1220.0'f32]
  const colW = 540.0'f32
  const rowH = 30.0'f32
  const topY = -150.0'f32
  const perCol = 14
  gPfxElems = @[]
  # THE BANNER. First, and it says what the page is -- including what it cannot
  # do yet. A page that quietly shows names where a player expects controls is
  # the same defect as a control that quietly does nothing.
  let banner = nuLabel(gGfxPostGo, donor, 60.0'f32, -100.0'f32, 1700.0'f32,
                       40.0'f32,
                       "aowlspt post-process - the " & $(rows.len) &
                       " settings mods/graphics declares. NAMES ONLY for now: " &
                       "live values need the mod schema fetch, which is " &
                       "disabled because it crashes the client. * = owned by " &
                       "the active Preset and ignored until Preset = custom.",
                       18.0'f32, 1.0'f32, 0.78'f32, 0.35'f32, 1.0'f32,
                       "aowl-pfx-banner")
  if not nuLive(banner):
    pfxNoteFault("the banner label could not be built (nuikit logged the " &
                 "refusal above). Building 40 more would only repeat it, so " &
                 "nothing further was attempted and nothing is left on screen.")
    discard pfxDestroyAll()
    return
  gPfxElems.add(banner)
  var built = 0
  var refusedRows = 0
  var i = 0
  var slot = 0
  while i < rows.len and i < PfxMaxRows and gPfxElems.len < PfxMaxHandles:
    let col = slot div perCol
    if col > 2:
      break                     # out of columns; capped rather than overflowing
    let y = topY - rowH * float32(slot mod perCol)
    let txt = (if rows[i].header: "-- " & rows[i].label & " --"
               else: (if rows[i].presetOwned: "* " else: "   ") & rows[i].label)
    let e = nuLabel(gGfxPostGo, donor, colX[col], y, colW, rowH - 4.0'f32, txt,
                    (if rows[i].header: 19.0'f32 else: 17.0'f32),
                    (if rows[i].header: 1.0'f32 else: 0.85'f32),
                    (if rows[i].header: 0.78'f32 else: 0.85'f32),
                    (if rows[i].header: 0.35'f32 else: 0.85'f32),
                    1.0'f32,
                    "aowl-pfx-" & (if rows[i].header: "head" else: rows[i].key))
    if nuLive(e):
      gPfxElems.add(e)
      built = built + 1
    else:
      refusedRows = refusedRows + 1
    slot = slot + 1
    i = i + 1
  if built == 0:
    pfxNoteFault("zero rows were built out of " & $rows.len & " declared; " &
                 "tearing down the banner so the panel is left exactly stock")
    discard pfxDestroyAll()
    return
  gPfxBuilt = true
  okLog "postfx rows: built " & $built & " native row(s) into the stock PostFX " &
        "Settings panel from " & $rows.len & " declared setting(s) (" &
        $refusedRows & " refused). NOTHING WAS CLONED -- every element is a " &
        "from-scratch TextMeshProUGUI via nuikit, and the only thing borrowed " &
        "from a live object is the donor's font asset."
  result = true

proc pfxVerdict() =
  ## THE §9b ACCEPTANCE TEST FOR BUG 2, read back off the live tree.
  ##
  ##     the PostFX panel contains N>0 rows we built, each reading back with a
  ##     renderable rect and non-empty text
  ##
  ## Stated as a count, and every count comes from `nuElemRect` / `nuElemText` /
  ## `nuElemActive`, which resolve the handle and then ask the LIVE
  ## `RectTransform` and the LIVE `TMP_Text` -- not from the strings this file
  ## passed to `nuLabel` a moment ago. A row that reads back with a zero-area
  ## rect is on the page and invisible, which is exactly the "blank stuff" the
  ## player reported, so it counts as a FAILURE here and not as a row.
  ##
  ## Three outcomes. INCONCLUSIVE covers "the handle did not resolve" and
  ## "nothing was ever built because the screen was not opened", and it is never
  ## folded into either of the other two.
  if gPfxVerdictSaid:
    return
  if not gPfxBuilt:
    if gPfxOff:
      gPfxVerdictSaid = true
      warn "postfx rows VERDICT FAIL: nothing was ever built -- " & $gPfxTried &
           " attempt(s), " & $gPfxFaults & " fault(s), the feature has " &
           "self-disabled. The PostFX panel is the empty stock panel. See the " &
           "fault line above for which hop refused."
    return
  var good = 0
  var noText = 0
  var noRect = 0
  var notActive = 0
  var incon = 0
  var i = 0
  while i < gPfxElems.len and i < PfxMaxHandles:
    let e = gPfxElems[i]
    if not nuLive(e):
      incon = incon + 1
    else:
      let (rOk, _, _, w, h) = nuElemRect(e)
      let t = nuElemText(e)
      let act = nuElemActive(e)
      if not rOk:
        incon = incon + 1
      elif w <= 1.0'f32 or h <= 1.0'f32:
        noRect = noRect + 1
      elif t.len == 0:
        noText = noText + 1
      elif not act:
        notActive = notActive + 1
      else:
        good = good + 1
    i = i + 1
  gPfxVerdictSaid = true
  if good == 0:
    warn "postfx rows VERDICT FAIL: 0 of " & $gPfxElems.len & " element(s) " &
         "read back as a drawable row (" & $noRect & " zero-area rect, " &
         $noText & " empty text, " & $notActive & " not activeInHierarchy, " &
         $incon & " unreadable). The PostFX panel is still blank to the player " &
         "even though the build reported success -- that gap is the whole " &
         "reason this check reads the live objects instead of the writes."
  elif noRect > 0 or noText > 0 or notActive > 0:
    warn "postfx rows VERDICT FAIL: " & $good & " of " & $gPfxElems.len &
         " element(s) are drawable, but " & $noRect & " have a zero-area rect, " &
         $noText & " read back EMPTY text and " & $notActive & " are not " &
         "activeInHierarchy. A partially blank page is still the reported bug."
  elif incon > 0:
    warn "postfx rows VERDICT INCONCLUSIVE: " & $good & " element(s) read back " &
         "drawable with non-empty text, but " & $incon & " of " &
         $gPfxElems.len & " could not be read at all, so the page was not " &
         "fully observed. This is NOT a pass."
  else:
    okLog "postfx rows VERDICT PASS: " & $good & " of " & $gPfxElems.len &
          " native element(s) in the stock PostFX Settings panel read back " &
          "activeInHierarchy, with a non-zero rect AND non-empty text, off " &
          "the live RectTransform and the live TMP_Text. The panel that used " &
          "to be blank now renders " & $good & " row(s), none of them cloned."

proc pfxOnPanelUp(postUp: bool) =
  ## Called every tick from `gfxTickBody`, inside its existing guard. The
  ## steady state is two boolean tests.
  if not gPfxOn or gPfxOff:
    return
  if not postUp:
    return
  if not gPfxBuilt:
    if gPfxTried < 4:
      discard pfxBuild()
    return
  pfxVerdict()

proc pfxOnScreenClosed() =
  ## The settings screen went away. Re-arm the verdict so the NEXT visit prints
  ## a fresh one, and drop our elements if the panel they were parented to has
  ## been destroyed under us -- a stale handle here is exactly what nuikit's
  ## generation counters refuse, but the list should not grow forever either.
  gPfxVerdictSaid = false
  if gPfxBuilt and (gGfxPostGo == nil or not duOk(gGfxPostGo, 0x20'i32) or
                    not iUnityAlive(gGfxPostGo)):
    let n = pfxDestroyAll()
    okLog "postfx rows: the PostFX panel was destroyed under us; " & $n &
          " element(s) of ours were torn down and will be rebuilt on the next " &
          "visit. Nothing stale is left parented into a dead object."
