## mods/maps/core/place.nim -- the maps widget's PURE decisions.
##
## Everything in this file is a function of numbers and strings. It calls no
## Unity, no IL2CPP, no region and no game memory, which is the whole point:
## `mods/maps/core/selftest.nim` runs it offline, in a process that has never
## seen Tarkov, and `aowl test --mod maps` gets a verdict in seconds instead of
## a build/deploy/launch/look-at-the-screen cycle.
##
## WHAT LIVES HERE AND WHY.
##
##  * The ANCHOR spelling table and `widgetOrigin`. `sp/hud.nim` keeps the C
##    implementation that actually draws (`mhud_widget_origin`), because the
##    origin has to be recomputed on the render thread against the measured back
##    buffer. This file is the SPEC that C implements, and the two are NOT
##    compared against each other -- comparing an implementation with its own
##    mirror is the check that cannot fail (CLAUDE.md 9b). Instead:
##      - offline, `selftest.nim` asserts a PROPERTY of `widgetOrigin`'s output
##        (the rect lies inside the back buffer, and it hugs the corner asked
##        for), across both of the user's resolutions and across insets large
##        enough to push it off-screen;
##      - live, `maps.nim` asserts the SAME property of `hudWidgetX/Y`, which is
##        what the C code actually resolved on the last drawn frame.
##    Both can fail. Neither restates the other.
##
##  * The DETAIL preset, the full-screen ACTIVATION mode, and the enemy
##    VISIBILITY policy -- three string-to-behaviour decisions that used to be
##    the kind of thing only a live raid could exercise.
##
## Nothing here is allowed to import `sp/`: that would drag in the region ABI
## and the selftest would stop building.

# ---------------------------------------------------------------------------
# ANCHORS
# ---------------------------------------------------------------------------

const
  AnchorManual* = 0
    ## `mapX`/`mapY` are the absolute top-left. The historical behaviour and the
    ## shipped default, so taking this build moves nobody's widget.
  AnchorTL* = 1
  AnchorTR* = 2
  AnchorBL* = 3
  AnchorBR* = 4

func anchorNameOf*(a: int): string =
  ## The canonical spelling of a resolved anchor, for the diag.
  case a
  of AnchorTL: "topleft"
  of AnchorTR: "topright"
  of AnchorBL: "bottomleft"
  of AnchorBR: "bottomright"
  else:        "manual"

func anchorOfName*(s: string): int =
  ## Text -> anchor. An unrecognised spelling resolves to MANUAL, which is the
  ## safe placement -- but note that this proc CANNOT tell a typo from someone
  ## deliberately asking for `manual`. That is what `anchorRecognisedName` is
  ## for, and why the two are separate procs rather than one clever one.
  case s
  of "topleft", "top-left", "tl":         AnchorTL
  of "topright", "top-right", "tr":       AnchorTR
  of "bottomleft", "bottom-left", "bl":   AnchorBL
  of "bottomright", "bottom-right", "br": AnchorBR
  else:                                   AnchorManual

func anchorRecognisedName*(s: string): bool =
  ## Whether `anchorOfName` actually KNOWS this spelling. The predicate that can
  ## fail: `anchorOfName("bottomleftt")` and `anchorOfName("manual")` both return
  ## AnchorManual, and only this can tell you which of the two happened.
  case s
  of "manual", "",
     "topleft", "top-left", "tl",
     "topright", "top-right", "tr",
     "bottomleft", "bottom-left", "bl",
     "bottomright", "bottom-right", "br": true
  else:                                   false

type
  Rect* = object
    x*, y*, w*, h*: float

func widgetOrigin*(anchor: int; scrW, scrH, size, insetX, insetY: float): Rect =
  ## Where the square widget goes, in back-buffer pixels, origin top-left.
  ##
  ## MANUAL: `insetX`/`insetY` ARE the top-left, verbatim and unclamped -- that
  ## is what every existing config already means, and clamping it would move
  ## widgets that nobody asked to move.
  ##
  ## A CORNER: the same two numbers become an inset from that corner, and the
  ## result is clamped into the back buffer. The clamp is not decoration. An
  ## off-screen widget and a widget that never armed are indistinguishable from
  ## the player's chair, and this mod has already shipped that ambiguity once.
  var x = insetX
  var y = insetY
  case anchor
  of AnchorTL:
    x = insetX
    y = insetY
  of AnchorTR:
    x = scrW - size - insetX
    y = insetY
  of AnchorBL:
    x = insetX
    y = scrH - size - insetY
  of AnchorBR:
    x = scrW - size - insetX
    y = scrH - size - insetY
  else:
    discard   # MANUAL: verbatim
  if anchor != AnchorManual:
    let maxX = (if scrW - size > 0.0: scrW - size else: 0.0)
    let maxY = (if scrH - size > 0.0: scrH - size else: 0.0)
    if x < 0.0: x = 0.0
    if y < 0.0: y = 0.0
    if x > maxX: x = maxX
    if y > maxY: y = maxY
  result = Rect(x: x, y: y, w: size, h: size)

func rectInside*(r: Rect; scrW, scrH: float): bool =
  ## THE NEGATIVE. "Does this rect lie wholly within the back buffer?" -- the
  ## one question a corner placement has to answer, phrased so that it can come
  ## back false. A widget bigger than the screen is reported as NOT inside
  ## rather than excused, because that is exactly the 4K-at-1.5x-scaling case
  ## that has to be visible in a log.
  result = r.x >= 0.0 and r.y >= 0.0 and
           r.x + r.w <= scrW and r.y + r.h <= scrH

func rectText*(r: Rect): string =
  ## One-line rect, for the log. Integers: sub-pixel noise in a placement line
  ## is what makes a "changed" test fire every frame.
  result = "x=" & $int(r.x) & " y=" & $int(r.y) &
           " w=" & $int(r.w) & " h=" & $int(r.h)

# ---------------------------------------------------------------------------
# LEVEL OF DETAIL
# ---------------------------------------------------------------------------
#
# A PRESET over the three layer switches, not a mask over them. The difference
# matters and was a deliberate choice:
#
# A mask (AND with each toggle) would have made `high` byte-identical to
# `custom` -- a control that does nothing, which is the thing this repo keeps
# paying for. A preset FORCES the three layers, so all four values produce a
# distinguishable (art, grid, pip) triple and the offline test can tell them
# apart. The cost is that a preset can override a switch the player set by
# hand; that is why `resolveDetail` reports `overrode`, and why `custom` (the
# default) touches nothing at all.

const
  DetailCustom* = 0
    ## The individual switches decide. The shipped default: taking this build
    ## changes nobody's map.
  DetailLow* = 1
  DetailMedium* = 2
  DetailHigh* = 3

func detailNameOf*(d: int): string =
  case d
  of DetailLow:    "low"
  of DetailMedium: "medium"
  of DetailHigh:   "high"
  else:            "custom"

func detailOfName*(s: string): int =
  case s
  of "low":    DetailLow
  of "medium", "med": DetailMedium
  of "high":   DetailHigh
  else:        DetailCustom

func detailRecognisedName*(s: string): bool =
  case s
  of "custom", "", "low", "medium", "med", "high": true
  else: false

type
  DetailLayers* = object
    art*: bool      ## submit the baked map artwork (the textured quads)
    grid*: bool     ## submit the scale grid
    pip*: bool      ## submit the amber north pip
    overrode*: bool ## the preset changed at least one of the three

func resolveDetail*(detail: int; art, grid, pip: bool): DetailLayers =
  ## The four presets, as four distinguishable outcomes:
  ##   custom -- pass the switches through untouched
  ##   low    -- art OFF, grid OFF, pip OFF (blips, player, border: the cheapest
  ##             pane this renderer can submit)
  ##   medium -- art OFF, grid ON, pip ON
  ##   high   -- art ON, grid ON, pip ON
  var a = art
  var g = grid
  var p = pip
  case detail
  of DetailLow:
    a = false; g = false; p = false
  of DetailMedium:
    a = false; g = true; p = true
  of DetailHigh:
    a = true; g = true; p = true
  else:
    discard
  result = DetailLayers(art: a, grid: g, pip: p,
                        overrode: (a != art or g != grid or p != pip))

# ---------------------------------------------------------------------------
# THE FULL-SCREEN MAP KEY: PRESS vs HOLD
# ---------------------------------------------------------------------------

const
  ActPress* = 0
    ## Edge-triggered TOGGLE. One press opens, the next (or Escape) closes.
    ## Reads `UnityEngine.Input::GetKeyDown`. The historical behaviour.
  ActHold* = 1
    ## The overlay is open exactly while the key is HELD, and closes the frame
    ## it is released. Reads `UnityEngine.Input::GetKey` instead -- a different
    ## method at a different, separately byte-verified RVA. Note what this
    ## implies and is stated in the schema: in HOLD mode Escape is not consulted
    ## at all, because releasing the key already closes it.

func activationNameOf*(a: int): string =
  if a == ActHold: "hold" else: "press"

func activationOfName*(s: string): int =
  case s
  of "hold", "held", "hold-to-show": ActHold
  else:                              ActPress

func activationRecognisedName*(s: string): bool =
  case s
  of "press", "", "toggle", "hold", "held", "hold-to-show": true
  else: false

func holdState*(activation: int; wasOpen, keyDownEdge, keyHeld, escDownEdge: bool): bool =
  ## The overlay's state AFTER one poll, as a pure function of the four input
  ## bits. Written here rather than only in C so that both activation modes can
  ## be driven offline over a sequence of frames -- which is the only way to
  ## assert the thing the user actually asked for ("HOLD shows while held and
  ## hides on release") without a human holding a key in a raid.
  ##
  ## PRESS: `keyHeld` is ignored entirely. HOLD: `keyDownEdge` and `escDownEdge`
  ## are ignored entirely -- the held state IS the answer, so there is no
  ## internal state that can get stuck open if a release edge is ever missed.
  ## That is the reason HOLD is a level read and not an edge pair.
  if activation == ActHold:
    result = keyHeld
  else:
    if keyDownEdge:
      result = not wasOpen
    elif wasOpen and escDownEdge:
      result = false
    else:
      result = wasOpen

# ---------------------------------------------------------------------------
# ENEMY VISIBILITY POLICY
# ---------------------------------------------------------------------------

const
  EnemyAlways* = 0
    ## Every contact that passes the class filters is drawn. The only policy
    ## this build can actually implement.
  EnemyShootOnly* = 1
    ## Draw a hostile contact only once it has FIRED. NOT AVAILABLE -- see
    ## `enemyPolicyAvailable`.

func enemyPolicyNameOf*(p: int): string =
  if p == EnemyShootOnly: "shootOnly" else: "always"

func enemyPolicyOfName*(s: string): int =
  case s
  of "shootOnly", "shoot-only", "shootonly", "onshot": EnemyShootOnly
  else:                                                EnemyAlways

func enemyPolicyRecognisedName*(s: string): bool =
  case s
  of "always", "", "shootOnly", "shoot-only", "shootonly", "onshot": true
  else: false

const EnemyShootOnlyWhy* =
  "shoot-only: NOT AVAILABLE -- there is no shot signal to gate on. This mod " &
  "does not consume mods/admin's feed at all (it does its own IL2CPP walk in " &
  "sp/world.nim), and nothing in the repo publishes a PER-CONTACT last-fired " &
  "time: admin measures NewRecoilShotEffect+0x11 for the LOCAL player's own " &
  "weapon only, which cannot say whether a bot 40 m away just fired. " &
  "Implementing this needs a measured field offset for a bot's last-shot time " &
  "(or a detour on the shot event) on build 1.1.0.1.46777, and none has been " &
  "taken. The policy in force is ALWAYS."

func enemyPolicyAvailable*(p: int): bool =
  ## The honest column. `shootOnly` is DECLARED so that the request is visible
  ## and named in the settings surface, and it is REFUSED at read time with
  ## `EnemyShootOnlyWhy` rather than being applied as a silent no-op -- a
  ## setting that stores a value and changes nothing is the failure mode this
  ## repo has paid for most often.
  result = p != EnemyShootOnly

func resolveEnemyPolicy*(p: int): int =
  ## What actually governs the draw. Always ALWAYS on this build; kept as a proc
  ## so that the day a shot signal exists, exactly one line changes and the
  ## offline test starts failing until it is updated.
  if enemyPolicyAvailable(p): p else: EnemyAlways

# ---------------------------------------------------------------------------
# THE OPTION LISTS THE SCHEMA OFFERS
# ---------------------------------------------------------------------------
#
# These are not a convenience. `maps.nim` passes these EXACT seqs to
# `enumSetting`, so the list the settings UI draws and the list the parser above
# understands are one object rather than two that drift.
#
# The bug this closes has already shipped in this mod: `widgetAnchor` offered a
# spelling set in the schema and `anchorOf` understood a different one, and the
# only thing that caught it was a player reporting that their corner did
# nothing. `selftest.nim` now asserts, for every string in every list here, that
# the parser recognises it and that name -> int -> name round-trips. That check
# fails the moment someone adds an option and forgets the parser.

proc detailOptions*(): seq[string] =
  result = @["custom", "low", "medium", "high"]

proc activationOptions*(): seq[string] =
  result = @["press", "hold"]

proc enemyPolicyOptions*(): seq[string] =
  result = @["always", "shootOnly"]

proc anchorOptions*(): seq[string] =
  result = @["manual", "topleft", "topright", "bottomleft", "bottomright"]

# ---------------------------------------------------------------------------
# THE SPATIAL WIDGET'S MODE
# ---------------------------------------------------------------------------
#
# This lived in sp/hud.nim, beside the C renderer, where the offline suite could
# not reach it -- so `spatialMode` was the ONE enum in this mod whose schema
# list was never checked against its own parser. That is precisely the defect
# `widgetAnchor` shipped and that these lists exist to prevent, and it was
# sitting unguarded while four other enums were covered. It is here now; hud.nim
# re-exports it, so every existing call site is unchanged.
#
# `auto` is DELIBERATELY not in this table. It is not a mode: it is an
# instruction to derive one from the legacy keys, resolved in maps.nim's
# readOpts before `modeOf` is ever called. Listing it here would mean
# `modeOf("auto")` had to answer some mode, and whichever one it answered would
# be wrong for half the configs.

const
  ModeOff* = 0
  ModeRadar* = 1
  ModeNorthUp* = 2
  ModeHeadUp* = 3
  ModeBoth* = 4
    ## The minimap AND the radar, two panes, one dispatch. It is the only mode
    ## entitled to more than one pane, and that entitlement is a number the
    ## draw ledger compares against -- never an exemption from the check.

proc modeNameOf*(m: int): string =
  case m
  of ModeRadar: "radar"
  of ModeNorthUp: "northup"
  of ModeHeadUp: "headingup"
  of ModeBoth: "both"
  else: "off"

proc modeRecognisedName*(s: string): bool =
  ## The predicate that CAN say no. `modeOfName` answers ModeOff for a typo AND
  ## for the literal word "off", so its return value alone cannot tell "the
  ## player asked for nothing" from "the player asked for something we did not
  ## understand" -- the same trap `anchorOf` set.
  case s
  of "off", "radar", "northup", "north-up", "minimap",
     "headingup", "heading-up", "rotating", "both", "radar+minimap": true
  else: false

proc modeOfName*(s: string): int =
  case s
  of "radar": ModeRadar
  of "northup", "north-up", "minimap": ModeNorthUp
  of "headingup", "heading-up", "rotating": ModeHeadUp
  of "both", "radar+minimap": ModeBoth
  else: ModeOff

proc modeOptions*(): seq[string] =
  ## The real modes -- what `modeOfName` parses. `auto` is NOT here: it is a
  ## migration instruction resolved in readOpts before `modeOfName` is called,
  ## and listing it would force the parser to answer some mode for it.
  result = @["off", "radar", "minimap", "headingup", "both"]

proc modeSchemaOptions*(): seq[string] =
  ## What the settings UI offers: the modes, with `auto` in front. One place
  ## builds this so the schema row and the parser cannot drift; the offline
  ## suite checks `modeOptions` (the parsable ones) and this list's tail
  ## against it.
  result = @["auto", "off", "radar", "minimap", "headingup", "both"]

proc modePanesExpected*(m: int; overlayOpen: bool): int =
  ## How many panes ONE dispatch in this mode is entitled to draw. The C
  ## renderer computes the same number in `mhud_pane_expect`; this copy exists
  ## so the offline suite can assert the TABLE (off draws none, both draws two,
  ## the overlay replaces the widget whatever the mode) without a running game.
  ## The two are asserted to agree by the live diag, which prints the C value.
  if overlayOpen: 1
  elif m == ModeOff: 0
  elif m == ModeBoth: 2
  else: 1
