## mods/maps/core/selftest.nim -- the maps mod's offline suite.
##
## Run it with `aowl test --mod maps`. Three outcomes, per CLAUDE.md 9b: exit 0
## every check passed, exit 1 a check FAILED, exit 3 the suite could not be
## found or built. There is deliberately no fourth outcome in which the harness
## shrugs.
##
## WHAT THIS SUITE IS FOR, AND WHAT IT CANNOT DO.
##
## It is for the decisions the maps mod makes that are functions of numbers and
## strings: where a corner-anchored widget lands, whether that rect is on the
## screen, which layers a detail preset resolves to, whether PRESS and HOLD
## behave differently over a sequence of frames, and whether every option the
## settings schema OFFERS is an option the parser UNDERSTANDS.
##
## It cannot tell you that the widget is visible in a raid. Nothing offline can.
## The live half of the same questions is asserted by `maps.nim`'s placement and
## master-gate log lines, which read the values the C renderer actually resolved
## on the last drawn frame -- so neither half is a restatement of the other.
##
## EVERY CHECK HERE IS WRITTEN SO IT CAN FAIL. Where a check asserts a property
## (`rectInside`), the suite also feeds it an input for which the property is
## FALSE and asserts that it comes back false -- a positive control for the
## negative. A `rectInside` that returned true unconditionally would pass the
## first half of this file and fail the second.

import place

type
  TestReport* = object
    lines*: seq[string]
    passed*: int
    failed*: int

proc check(r: var TestReport; name: string; ok: bool; got: string) =
  if ok:
    r.passed = r.passed + 1
    r.lines.add "ok    " & name
  else:
    r.failed = r.failed + 1
    r.lines.add "FAIL  " & name & " (got " & got & ")"

# ---------------------------------------------------------------------------
# 1. PLACEMENT -- the four corners at the two resolutions the user runs
# ---------------------------------------------------------------------------

proc placementChecks(r: var TestReport) =
  ## 1920x1080 and 3840x2160. The second is not decoration: the user runs 4K at
  ## 1.5x scaling, which is precisely the case an absolute-pixel placement gets
  ## wrong and a corner anchor is supposed to get right.
  ##
  ## The property asserted is the one that matters -- THE RECT IS ON THE SCREEN
  ## -- not "the arithmetic is the arithmetic I just wrote".
  let sizes = @[220.0, 720.0]
  let insets = @[0.0, 24.0, 48.0, 320.0]
  var screens: seq[Rect] = @[]
  screens.add Rect(x: 0.0, y: 0.0, w: 1920.0, h: 1080.0)
  screens.add Rect(x: 0.0, y: 0.0, w: 3840.0, h: 2160.0)
  let corners = @[AnchorTL, AnchorTR, AnchorBL, AnchorBR]

  var offCount = 0
  var worst = ""
  for s in screens:
    for size in sizes:
      for inset in insets:
        for a in corners:
          let rc = widgetOrigin(a, s.w, s.h, size, inset, inset)
          if not rectInside(rc, s.w, s.h):
            offCount = offCount + 1
            worst = anchorNameOf(a) & " size=" & $int(size) &
                    " inset=" & $int(inset) &
                    " on " & $int(s.w) & "x" & $int(s.h) & " -> " & rectText(rc)
  check(r, "every corner rect is inside the back buffer (2 res x 2 sizes x 4 insets x 4 corners)",
        offCount == 0,
        $offCount & " off-screen, e.g. " & worst)

  # THE POSITIVE CONTROL FOR THE NEGATIVE. If `rectInside` could not say no,
  # the check above would be worthless. A widget wider than the screen must come
  # back NOT inside.
  let tooBig = Rect(x: 0.0, y: 0.0, w: 2200.0, h: 2200.0)
  check(r, "rectInside CAN fail (a 2200px widget on 1920x1080 is not inside)",
        not rectInside(tooBig, 1920.0, 1080.0),
        "rectInside returned true for a rect larger than the screen")
  check(r, "rectInside CAN fail (a negative origin is not inside)",
        not rectInside(Rect(x: -1.0, y: 0.0, w: 10.0, h: 10.0), 1920.0, 1080.0),
        "rectInside accepted x=-1")

  # THE CORNER IS ACTUALLY THE CORNER. An anchor that clamped everything to
  # (0,0) would pass "inside the back buffer" perfectly, so the placement has to
  # be asserted as well as the containment.
  let tl = widgetOrigin(AnchorTL, 1920.0, 1080.0, 220.0, 24.0, 24.0)
  let tr = widgetOrigin(AnchorTR, 1920.0, 1080.0, 220.0, 24.0, 24.0)
  let bl = widgetOrigin(AnchorBL, 1920.0, 1080.0, 220.0, 24.0, 24.0)
  let br = widgetOrigin(AnchorBR, 1920.0, 1080.0, 220.0, 24.0, 24.0)
  check(r, "topleft hugs the left and top edges",
        tl.x < tr.x and tl.y < bl.y, rectText(tl))
  check(r, "topright hugs the right edge and the top",
        tr.x > tl.x and tr.y == tl.y, rectText(tr))
  check(r, "bottomleft hugs the left edge and the bottom",
        bl.x == tl.x and bl.y > tl.y, rectText(bl))
  check(r, "bottomright hugs the right edge and the bottom",
        br.x == tr.x and br.y == bl.y, rectText(br))
  check(r, "topright at inset 24 on 1920 wide lands at x=1676 (1920-220-24)",
        tr.x == 1676.0, rectText(tr))
  check(r, "bottomright at inset 24 on 2160 tall lands at y=1416 (2160-720-24)",
        widgetOrigin(AnchorBR, 3840.0, 2160.0, 720.0, 24.0, 24.0).y == 1416.0,
        rectText(widgetOrigin(AnchorBR, 3840.0, 2160.0, 720.0, 24.0, 24.0)))

  # MANUAL IS UNTOUCHED. The migration promise: nobody's widget moves.
  let man = widgetOrigin(AnchorManual, 1920.0, 1080.0, 720.0, 320.0, 120.0)
  check(r, "manual placement passes mapX/mapY through verbatim and unclamped",
        man.x == 320.0 and man.y == 120.0, rectText(man))
  let manOff = widgetOrigin(AnchorManual, 1920.0, 1080.0, 720.0, 5000.0, 5000.0)
  check(r, "manual placement is NOT clamped (an absolute config keeps its number)",
        manOff.x == 5000.0, rectText(manOff))

  # A widget bigger than the screen in a CORNER mode clamps to 0 rather than
  # going negative -- it is still not `rectInside`, and it must not pretend.
  let huge = widgetOrigin(AnchorBR, 1920.0, 1080.0, 2200.0, 24.0, 24.0)
  check(r, "a corner widget larger than the screen clamps to the origin",
        huge.x == 0.0 and huge.y == 0.0, rectText(huge))
  check(r, "...and is still reported as NOT inside, not excused",
        not rectInside(huge, 1920.0, 1080.0), rectText(huge))

# ---------------------------------------------------------------------------
# 2. THE DETAIL PRESET -- four distinguishable outcomes
# ---------------------------------------------------------------------------

func trip(d: DetailLayers): string =
  ## The three layers as one comparable token, so "these two presets are
  ## different" is a string inequality rather than three separate asserts that
  ## could each pass while the triple is identical.
  result = (if d.art: "A" else: "-") &
           (if d.grid: "G" else: "-") &
           (if d.pip: "P" else: "-")

proc detailChecks(r: var TestReport) =
  # From all-on switches, the four presets must produce FOUR DIFFERENT triples.
  # This is the check that would have caught `high` being a synonym for
  # `custom` -- a control that does nothing.
  let c = resolveDetail(DetailCustom, true, true, true)
  let l = resolveDetail(DetailLow, true, true, true)
  let m = resolveDetail(DetailMedium, true, true, true)
  let h = resolveDetail(DetailHigh, true, true, true)
  check(r, "custom passes the switches through untouched", trip(c) == "AGP", trip(c))
  check(r, "low submits no art, no grid, no pip", trip(l) == "---", trip(l))
  check(r, "medium submits grid and pip but no art", trip(m) == "-GP", trip(m))
  check(r, "high submits all three", trip(h) == "AGP", trip(h))
  check(r, "low, medium and custom are three DIFFERENT outcomes",
        trip(l) != trip(m) and trip(m) != trip(c) and trip(l) != trip(c),
        trip(l) & "/" & trip(m) & "/" & trip(c))

  # `high` is a PRESET, so from switches that are off it must turn them on --
  # that is what makes it distinguishable from `custom`, which must not.
  let hOff = resolveDetail(DetailHigh, false, false, false)
  let cOff = resolveDetail(DetailCustom, false, false, false)
  check(r, "high FORCES the layers on even when the switches are off",
        trip(hOff) == "AGP", trip(hOff))
  check(r, "custom leaves off switches off", trip(cOff) == "---", trip(cOff))
  check(r, "high and custom are distinguishable from off switches",
        trip(hOff) != trip(cOff), trip(hOff) & "/" & trip(cOff))

  # `overrode` is what the diag reports so a player who set a switch by hand and
  # then picked a preset is TOLD the preset won, rather than left wondering.
  check(r, "overrode is true when the preset changed a switch", hOff.overrode,
        "overrode was false while high turned three switches on")
  check(r, "overrode is false when custom changed nothing", not cOff.overrode,
        "custom claimed to have overridden something")

# ---------------------------------------------------------------------------
# 3. PRESS vs HOLD, driven over a sequence of frames
# ---------------------------------------------------------------------------

proc activationChecks(r: var TestReport) =
  ## The user's requirement, stated as a trajectory rather than a single call:
  ## "PRESS toggles; HOLD shows while held and hides on release." A one-frame
  ## assertion cannot see either of those.

  # PRESS: a down-edge toggles, and holding the key afterwards must NOT keep
  # re-toggling. The frames are (downEdge, held).
  var open = false
  var flips = 0
  let pressEdge = @[false, true,  false, false, false, true,  false]
  let pressHeld = @[false, true,  true,  true,  false, true,  false]
  var pi = 0
  while pi < pressEdge.len:
    let was = open
    open = holdState(ActPress, open, pressEdge[pi], pressHeld[pi], false)
    if open != was: flips = flips + 1
    pi = pi + 1
  check(r, "PRESS: two down-edges across seven frames produce exactly two flips",
        flips == 2, $flips & " flips")
  check(r, "PRESS: the overlay is CLOSED after the second press", not open,
        "still open")

  # PRESS: Escape closes an open overlay and does nothing to a closed one.
  check(r, "PRESS: Escape closes an open overlay",
        not holdState(ActPress, true, false, false, true), "stayed open")
  check(r, "PRESS: Escape on a closed overlay does not open it",
        not holdState(ActPress, false, false, false, true), "opened on Escape")

  # HOLD: the state IS the held bit. Shown while held, hidden the frame it is
  # released, and -- the property that matters for "never leave input captured"
  # -- there is no sequence of inputs that leaves it stuck open.
  var hopen = false
  var shown = 0
  let holdFrames = @[false, true, true, true, false, false, true, false]
  var stuck = false
  for held in holdFrames:
    hopen = holdState(ActHold, hopen, false, held, false)
    if hopen: shown = shown + 1
    if hopen != held: stuck = true
  check(r, "HOLD: the overlay is open on exactly the four held frames",
        shown == 4, $shown & " open frames")
  check(r, "HOLD: the overlay's state always equals the held bit (never stuck open)",
        not stuck, "the overlay state diverged from the held bit")
  check(r, "HOLD: a missed down-edge cannot leave it open",
        not holdState(ActHold, true, false, false, false), "stayed open on release")
  check(r, "HOLD ignores the down-edge entirely (it is a level read)",
        not holdState(ActHold, false, true, false, false),
        "a down-edge opened a HOLD overlay with the key not held")

  # PRESS and HOLD must actually behave differently on the same input, or one
  # of them is not implemented.
  check(r, "PRESS and HOLD differ on the same frame (key held, no edge)",
        holdState(ActPress, false, false, true, false) !=
        holdState(ActHold, false, false, true, false),
        "the two activation modes produced the same answer")

# ---------------------------------------------------------------------------
# 4. SCHEMA ROUND-TRIP -- every option offered is an option understood
# ---------------------------------------------------------------------------

proc schemaChecks(r: var TestReport) =
  ## The failure this closes: an enum row offers a spelling in the settings UI
  ## that the mod's own reader does not parse, so selecting it silently falls
  ## back to the default. `widgetAnchor` shipped exactly that.
  var bad = ""
  var n = 0

  let anchors = anchorOptions()
  let details = detailOptions()
  let acts = activationOptions()
  let pols = enemyPolicyOptions()
  let modes = modeOptions()

  for s in anchors:
    n = n + 1
    if not anchorRecognisedName(s): bad = bad & " anchor:" & s
    elif anchorNameOf(anchorOfName(s)) != s: bad = bad & " anchor-roundtrip:" & s
  for s in details:
    n = n + 1
    if not detailRecognisedName(s): bad = bad & " detail:" & s
    elif detailNameOf(detailOfName(s)) != s: bad = bad & " detail-roundtrip:" & s
  for s in acts:
    n = n + 1
    if not activationRecognisedName(s): bad = bad & " activation:" & s
    elif activationNameOf(activationOfName(s)) != s:
      bad = bad & " activation-roundtrip:" & s
  for s in pols:
    n = n + 1
    if not enemyPolicyRecognisedName(s): bad = bad & " enemy:" & s
    elif enemyPolicyNameOf(enemyPolicyOfName(s)) != s:
      bad = bad & " enemy-roundtrip:" & s

  # THE MODE TABLE, which until this build was the ONE enum in this mod whose
  # schema list was never checked against its own parser -- exactly the defect
  # `widgetAnchor` shipped. `minimap` is offered as the friendly spelling and
  # `northup` is the canonical one, so this list is checked for RECOGNITION and
  # for a stable int, and the round-trip is asserted separately below on the
  # canonical spellings only. A blanket name round-trip here would have forced
  # the schema to offer `northup` instead of `minimap`, which is a worse label
  # for a worse reason.
  for s in modes:
    n = n + 1
    if not modeRecognisedName(s): bad = bad & " mode:" & s
    elif modeOfName(s) == ModeOff and s != "off":
      bad = bad & " mode-falls-to-off:" & s

  check(r, "every option in every enum the schema offers parses and round-trips (" & $n & " options)",
        bad.len == 0, "unparsed or non-round-tripping:" & bad)

  # THE POSITIVE CONTROL. A recogniser that said yes to everything would pass
  # the loop above vacuously.
  check(r, "the anchor recogniser CAN say no",
        not anchorRecognisedName("bottomleftt"), "accepted a typo")
  check(r, "the detail recogniser CAN say no",
        not detailRecognisedName("ultra"), "accepted 'ultra'")
  check(r, "the activation recogniser CAN say no",
        not activationRecognisedName("doubletap"), "accepted 'doubletap'")
  check(r, "the enemy-policy recogniser CAN say no",
        not enemyPolicyRecognisedName("onsight"), "accepted 'onsight'")

  # And a typo must resolve to the SAFE value, not to some third state.
  # THE TWO MODE LISTS MAY NOT DRIFT. The schema offers `auto` plus the modes;
  # the parser understands the modes. If someone adds a mode to one list only,
  # the settings UI grows an option that silently falls back -- the exact defect
  # `widgetAnchor` shipped -- or a parsable mode becomes unreachable from the UI.
  block:
    let sch = modeSchemaOptions()
    let par = modeOptions()
    var same = sch.len == par.len + 1 and sch.len > 0 and sch[0] == "auto"
    if same:
      var i = 0
      while i < par.len:
        if sch[i + 1] != par[i]: same = false
        i = i + 1
    check(r, "the schema's mode list is exactly `auto` + the parsable modes",
          same, "schema and parser mode lists have drifted")
    check(r, "`auto` is NOT a parsable mode (it is a migration instruction)",
          not modeRecognisedName("auto"), "the parser claims to understand auto")

  check(r, "the mode recogniser CAN say no",
        not modeRecognisedName("minimapp"), "accepted a typo")
  check(r, "an unrecognised mode resolves to OFF, not to some third surface",
        modeOfName("minimapp") == ModeOff, modeNameOf(modeOfName("minimapp")))
  check(r, "the canonical mode spellings round-trip",
        modeNameOf(modeOfName("off")) == "off" and
        modeNameOf(modeOfName("radar")) == "radar" and
        modeNameOf(modeOfName("northup")) == "northup" and
        modeNameOf(modeOfName("headingup")) == "headingup" and
        modeNameOf(modeOfName("both")) == "both",
        "a canonical spelling did not survive name -> int -> name")
  check(r, "`minimap` and `northup` are the SAME mode (one surface, two names)",
        modeOfName("minimap") == modeOfName("northup"), "they differ")
  check(r, "`both` is a mode of its own, not an alias of either half",
        modeOfName("both") != modeOfName("radar") and
        modeOfName("both") != modeOfName("northup"), "both aliases a half")

  check(r, "an unrecognised anchor resolves to manual",
        anchorOfName("bottomleftt") == AnchorManual, anchorNameOf(anchorOfName("bottomleftt")))
  check(r, "an unrecognised detail resolves to custom",
        detailOfName("ultra") == DetailCustom, detailNameOf(detailOfName("ultra")))
  check(r, "an unrecognised activation resolves to press",
        activationOfName("doubletap") == ActPress, activationNameOf(activationOfName("doubletap")))

# ---------------------------------------------------------------------------
# 4b. THE PANE ENTITLEMENT -- how many panes a mode may draw
# ---------------------------------------------------------------------------

proc paneChecks(r: var TestReport) =
  ## `both` is the only mode allowed a second pane, and the ledger in the C
  ## renderer enforces that by comparing the panes drawn against this number.
  ## The number is therefore load-bearing and is asserted here, INCLUDING the
  ## cases that must NOT be 2 -- a table that answered 2 for everything would
  ## make the over-draw check vacuous, which is the failure this whole file is
  ## about.
  check(r, "off draws NO pane", modePanesExpected(ModeOff, false) == 0,
        $modePanesExpected(ModeOff, false))
  check(r, "radar draws exactly one", modePanesExpected(ModeRadar, false) == 1,
        $modePanesExpected(ModeRadar, false))
  check(r, "northup draws exactly one", modePanesExpected(ModeNorthUp, false) == 1,
        $modePanesExpected(ModeNorthUp, false))
  check(r, "headingup draws exactly one", modePanesExpected(ModeHeadUp, false) == 1,
        $modePanesExpected(ModeHeadUp, false))
  check(r, "both draws exactly TWO", modePanesExpected(ModeBoth, false) == 2,
        $modePanesExpected(ModeBoth, false))
  # THE NEGATIVE CONTROL. If the table simply returned 2 whenever a map is on,
  # the check above would pass and the over-draw ledger would be worthless.
  check(r, "no single-surface mode is entitled to two panes",
        modePanesExpected(ModeRadar, false) < 2 and
        modePanesExpected(ModeNorthUp, false) < 2 and
        modePanesExpected(ModeHeadUp, false) < 2,
        "a single-surface mode claimed two panes")
  # The overlay REPLACES the widget. `both` with the map open must still be 1,
  # or the fullscreen suppression assertion in the renderer would read FAIL on
  # every frame the overlay is open in that mode.
  check(r, "the overlay replaces the widget -- one pane whatever the mode",
        modePanesExpected(ModeBoth, true) == 1 and
        modePanesExpected(ModeRadar, true) == 1 and
        modePanesExpected(ModeOff, true) == 1,
        "the overlay did not collapse the entitlement to one")

# ---------------------------------------------------------------------------
# 5. THE ENEMY POLICY IS DECLARED UNAVAILABLE, NOT SILENTLY IGNORED
# ---------------------------------------------------------------------------

proc enemyChecks(r: var TestReport) =
  check(r, "shootOnly parses (the request is understood, not dropped)",
        enemyPolicyOfName("shootOnly") == EnemyShootOnly,
        enemyPolicyNameOf(enemyPolicyOfName("shootOnly")))
  check(r, "shootOnly is declared NOT AVAILABLE on this build",
        not enemyPolicyAvailable(EnemyShootOnly), "claimed to be available")
  check(r, "always IS available", enemyPolicyAvailable(EnemyAlways), "declared unavailable")
  check(r, "shootOnly resolves to ALWAYS rather than to an empty map",
        resolveEnemyPolicy(EnemyShootOnly) == EnemyAlways,
        enemyPolicyNameOf(resolveEnemyPolicy(EnemyShootOnly)))
  check(r, "the refusal names the missing measurement, not just 'unsupported'",
        EnemyShootOnlyWhy.len > 200, "the explanation is " & $EnemyShootOnlyWhy.len & " chars")

proc run*(): TestReport =
  var r = TestReport(lines: @[], passed: 0, failed: 0)
  r.lines.add "mods/maps/core -- placement, detail, activation, schema, panes, policy"
  placementChecks(r)
  detailChecks(r)
  activationChecks(r)
  schemaChecks(r)
  paneChecks(r)
  enemyChecks(r)
  result = r
