## aowlspt/maps -- one spatial-awareness mod: map, radar, direction indicators.
##
## ## Why these three are one mod and not three
##
## They are three renderings of ONE question: where is everything relative to
## me. A map is that question drawn at world scale, a radar is the same answer
## clipped to a radius and centred on the player, and the direction indicators
## are the same answer reduced to a bearing. Built as three ports they would be
## three collectors racing each other over the same game memory, three sets of
## offsets to invalidate on the next Tarkov update, and three places for a bad
## read to kill the client. Built as one they are a single guarded collector
## (`sp/world.nim`) publishing a single snapshot, and three pure-arithmetic
## views over it that touch no game memory at all.
##
## The upstream projects this behaviour is specified from are BepInEx/Mono mods
## for pre-1.0 EFT. None of their code is carried over and none of it could be:
## post-1.0 EFT is IL2CPP, there is no BepInEx, there is no Mono patching, and
## every one of their Harmony patches is a by-name route that is fatal on this
## build (fact #145). They are read as a specification of *what to show*. The
## map TERRAIN ART and the map CALIBRATION under `data/maps/` are the one thing
## genuinely reused -- they are data, not code. Provenance is in
## `data/maps/README.md`.
##
## ## The split, and why the map is a browser page
##
##   client side  ->  read positions, publish a snapshot   (sp/world.nim)
##   server side  ->  serve the terrain, the calibration and the snapshot
##   browser      ->  draw all three views                 (sp/page.nim)
##
## The draw surface is a browser page, not native Unity UI. That is a decision
## taken for us: this project spent days trying to extend Tarkov's own settings
## screen and got nowhere, so native UI is off the table. What is left is the
## D3D11 overlay or a browser page, and for THIS feature the browser is not a
## consolation prize -- it is better. An SVG map needs pan, zoom, layer
## switching, hit-testing and a vector rasteriser; a browser has all five and
## the overlay has a hand-written per-shape C renderer with a bitmap font. The
## overlay would have meant writing an SVG rasteriser in C inside the game's
## Present hook.
##
## That reasoning still holds FOR THE MAP -- an SVG map wants pan, zoom, layer
## switching and hit-testing, and the overlay would have meant writing an SVG
## rasteriser in C inside the game's Present hook.
##
## It no longer holds for the radar and the indicators, and they are no longer
## browser-only. What blocked them was stated here as "ownership of the existing
## ESP draw region"; that was the right hazard (a second detour overwrites the
## first's trampoline) and the wrong conclusion. `abi/aowlspt_region.h` is the
## shared per-frame region built for exactly this: register a DRAW callback,
## ride the ONE existing dispatch point, submit POD screen-space commands, and
## let the overlay rasterise them. `sp/hud.nim` does that, with its own draw
## budget and its own meter. No second hook, and nothing borrowed from
## `abi/aowlspt_admin.h`.
##
## The region is armed by the HOST flag `sharedRegion`, default OFF. A mod's
## registration always succeeds; a registered participant on an unarmed region
## never fires. Those are reported as two different states, never as one.
##
## ## The client -> server channel
##
## The client host and the backend are SEPARATE PROCESSES, so the snapshot has
## to cross. It crosses as a small file in the shared install directory,
## written temp-then-rename so a reader can never see a half-written snapshot.
##
## The write happens on the MOD's own timer thread, never on Unity's. The Unity
## thread's entire job is `collect()` -- raw guarded reads into a preallocated
## buffer -- and it does no formatting, no file IO and no allocation beyond the
## bounded id labels. That is the "no per-frame managed allocation" rule kept
## honestly rather than asserted.
##
## ## Flags, default OFF
##
## `config.json` and the F12 schema (`spatialSchema`): `enabled` (false), `hz`
## (10), `radiusM` (120), plus the HUD block. With `enabled`
## false the client half registers no tick at all and never resolves the host
## export, so it cannot touch game memory even by accident. The SERVER half
## still serves the terrain and the calibration -- browsing the maps offline is
## harmless and needs no client.

import std/syncio
import aowlspt
import aowlspt/server as sv
import aowlspt/sync
import aowlspt/settings   # the F12 schema this mod declares -- see `spatialSchema`
import aowlspt/json as jr # field/asText -- the edited KEY out of a POST body
import sp / world
import sp / mapsprof
import diagfilter   # the verdict-signature log filter; tested in tests/mapsdiag
{.emit: """
#include "sp/mapsprof.h"   /* prototypes only; sp/mapsprof.nim owns the state */
""".}
import sp / hud
import sp / serve
import sp / page

const
  ModGuid* = "aowl.maps"
  ModName* = "Maps"
    ## Was "Spatial". That was an internal word for the position feed; the
    ## player-facing surface is a map, and this string is what both the mod
    ## list and the F12 settings nav display (`modName()` in aowlspt/settings).
    ## A plain name covering all three views. Not "DynamicMaps", not "Radar",
    ## not any upstream project's name: another agent owns user-facing naming
    ## and no upstream branding is carried into anything a player sees.
  ModAuthor* = "aowlspt"
  ModVersion* = "0.1.0"

var gEnabled = false
var gHz = 10
var gRadius = 120.0

# The one snapshot, and the one lock over it. `collect` fills it on Unity's
# thread; the publish timer serialises it on the mod's thread. Two threads, one
# object, so it is guarded -- `aowlspt/sync`'s lock belongs to this library
# alone and cannot contend with any other mod's.
var gSnap: Snapshot
var gPending = false
var gTicks = 0'i64
var gPublished = 0'i64
var gLastErr = ""

# ---------------------------------------------------------------------------
# The in-game HUD's layout, and the F12 settings schema
# ---------------------------------------------------------------------------
#
# WHICH SIDE THIS MOD IS ON. `sides` below is `{sideServer, sideClient}`, so
# this mod loads in BOTH processes and `onLoad` runs twice. `declareSettings`
# and the settings routes are therefore installed unconditionally, before the
# side split -- exactly as mods/admin does -- which means the SERVER-process
# instance is the one settingshub's index broadcast sees. That is deliberate
# and it is the reason this mod needs no second mechanism for client-side
# settings reach: the schema is declared by a server-process instance already.
# The CLIENT-process instance reads the same keys out of the same config.json
# at load, so a value written through F12 takes effect on the next load. Live
# re-application without a reload is NOT wired, and is not claimed to be.
#
# SCREEN SIZE IS A SETTING, and it should not have to be. `aowlspt_region.h`
# has `screenW`/`screenH` in its state and an `aowl_region_set_screen` to fill
# them, but on this branch NOTHING calls that setter and no getter is exported,
# so a mod cannot ask the region how big the back buffer is. Rather than guess
# from a value that is provably always 0, the layout takes the resolution from
# config. Raised as a gap in the report; the fix belongs in the region and the
# overlay, not here.

var gOpts: HudOpts
var gHudOn = false
var gHudRefusal = ""
  ## The reason `hudRegister` gave the LAST time it actually refused, captured at
  ## the refusal site. Empty means registration was never attempted OR it
  ## succeeded -- `gHudTried` tells those two apart. This exists because the
  ## `region` diag line used to ASSERT a cause ("radar, map and indicators are
  ## all off in config.json") that it had not measured: on the 2026-09-04 run
  ## the live config held spatialMode=radar and enabled=false, so every clause
  ## of that sentence was false and the one true cause was not named. A verdict
  ## may only report a cause it read.
var gHudTried = false
  ## True once `armFeed` has reached the registration decision at all. False
  ## means `onLoad` returned at the `enabled=false` gate and no registration was
  ## ever attempted -- which is a deliberately-disabled feature, not a failure.
var gFeedRunning = false
  ## True once the client-side collector and publish timer are actually
  ## registered. This is NO LONGER load-time-only: `armFeed` is called from the
  ## apply hook too, so a session that booted with `enabled=false` can arm the
  ## feed mid-raid. It is the guard that makes `armFeed` idempotent for the two
  ## timers, and the diag reads it to tell "ON in config but NEVER ARMED" (the
  ## late-arm bug) apart from "ON and drawing".
var gArmedAtBoot = false
  ## Whether onLoad itself armed the feed. False means the session booted with
  ## `enabled=false`; any drawing after that came from a LATE ARM, and the diag
  ## says so rather than leaving the two indistinguishable.
var gLateArms = 0
  ## How many times the apply hook actually performed an arming step. IDEMPOTENCE
  ## EVIDENCE: toggling on/off/on/off/on must leave this at the number of
  ## false->true transitions that found something unarmed -- in practice 1 --
  ## because `armFeed` is guarded by gFeedRunning and gHudOn. A value that climbs
  ## with every toggle would mean duplicate timers or duplicate draw
  ## participants, and it would be visible here on the very next diag tick.
var gDiagOn = false
  ## The periodic diagnostic timer is registered exactly once, UNCONDITIONALLY,
  ## before the `enabled` gate in onLoad. It used to be registered after that
  ## gate, so a session that booted disabled produced NO `maps diag` block at
  ## all -- which is how a silent late-arm no-op survived a whole session: there
  ## was nothing in the log that could have contradicted it. A diag that only
  ## runs when the feature already works is a check that cannot fail.
const
  ReconcilePeriodMs* = 1000
  MaxReconcileFails* = 5

var gReconcileOn = false
  ## Whether the cross-process config reconcile timer is registered. See the
  ## long block above `mirrorDrift`: the F12 write lands in the SERVER process
  ## and the draw mirror lives here, so watching config.json is the only choke
  ## point both sides share.
var gReconciles = 0
var gReconcileFails = 0
var gReconcileOff = false
var gLastDrift = ""

proc near(a, b: float): bool =
  ## Float equality with a tolerance, for the reconcile's finished-state
  ## comparison AND for the placement verdict. 0.01 px/m is far below anything a
  ## control can express and far above JSON round-tripping, so it can absorb a
  ## re-serialisation and nothing a user could have typed.
  ##
  ## Declared here, above both users, rather than beside the reconcile: the
  ## placement verdict needs it too, and two tolerances for "is this the same
  ## number" would be two ways to disagree.
  let d = a - b
  (if d < 0.0: -d else: d) <= 0.01

var gRadarAnchorRefused = ""
  ## Same once-per-distinct-bad-value contract as `gAnchorRefused` below, for
  ## the radar sub-widget's corner. Kept SEPARATE rather than shared, so a typo
  ## in one key cannot suppress the refusal for the other.
var gAnchorRefused = ""
  ## The last `widgetAnchor` text this build did not recognise, so the refusal is
  ## logged once per distinct bad value rather than once a second forever
  ## (readOpts is on the reconcile's tick). Empty means the configured spelling
  ## is one we accept.

var gActRefused = ""
var gDetailRefused = ""
var gEnemyRefused = ""
  ## Same contract as `gAnchorRefused` above, one per new enum: the LAST text
  ## this build did not accept, so a refusal is logged once per distinct bad
  ## value instead of once a second forever. Empty = the configured spelling is
  ## one we accept. `gEnemyRefused` additionally latches an accepted-but-
  ## UNAVAILABLE value (`shootOnly`), because "we understood you and cannot do
  ## it" has to be said exactly as loudly as "we did not understand you".

var gDetailOverrode = ""
  ## The last detail preset -> layer resolution that CHANGED one of the three
  ## layer switches, so the override is announced on change rather than every
  ## reconcile. A preset quietly winning over a switch the player set by hand is
  ## precisely the silent-no-op failure this mod keeps paying for.

var gMasterState = -1
  ## The last `enabled` state the master-gate line reported: -1 never reported,
  ## 0 off, 1 on. Drives one log line per STATE CHANGE, never per frame.
var gMasterGatedAt = 0'i64
  ## `hudGated()` at the moment the feature was switched off, so the OFF line
  ## can quote the number of dispatches that have since submitted zero
  ## primitives. A count taken from the moment of the edit is falsifiable: if
  ## the gate were not doing its job the delta would stay at 0 while frames ran.

var gPlaceLast = ""
  ## The last placement line emitted, so the resolved widget rect is logged once
  ## per change rather than once a frame.

var gDrawVerdictFrames = 300
  ## How many IN-RAID dispatches may pass with a surface selected and nothing
  ## submitted before the draw verdict stops saying INCONCLUSIVE and says FAIL.
  ## Read from config each readOpts. The bound is the whole point: an
  ## unbounded "nothing has drawn YET" is a verdict no input can falsify, and
  ## this mod has already paid for one of those.

var gHeadingOn = false
  ## The `heading` setting. Flag-gated and default OFF, like everything else
  ## here. When off, the measured heading is DISCARDED at publish time rather
  ## than merely ignored downstream, so "heading-up" and "north-up" remain one
  ## decision made in one place; hud.nim reads `rot` from a single variable and
  ## both the radar and the map pane follow it together.

var gFsKeyName = ""
var gFsKeyKc = -1
  ## The full-screen toggle key, resolved from its NAME once per apply. -1 is
  ## UNBOUND and is the shipped default for `hotkeys` being off; a name that is
  ## not a KeyCode also resolves to -1, and the diag distinguishes the two
  ## rather than reporting a misspelling as "no key configured".
var gFsHotkeysOn = false

proc parseRgb(s: string; dflt: uint32): uint32 =
  ## "RRGGBB" or "#RRGGBB" -> the region's RGBA packing, alpha 235.
  ##
  ## A MALFORMED string returns the DEFAULT and does not silently become black:
  ## a black contact mark on a dark map is invisible, which is indistinguishable
  ## from "contacts are not being drawn" -- the exact ambiguity this project
  ## keeps paying for. The diag prints the colour actually in force.
  var t = ""
  for c in s:
    if c != '#' and c != ' ': t.add c
  if t.len != 6: return dflt
  var v = 0'u32
  for c in t:
    var d = 0'u32
    if c >= '0' and c <= '9': d = uint32(ord(c) - ord('0'))
    elif c >= 'a' and c <= 'f': d = uint32(ord(c) - ord('a') + 10)
    elif c >= 'A' and c <= 'F': d = uint32(ord(c) - ord('A') + 10)
    else: return dflt
    v = v * 16'u32 + d
  let r = (v shr 16) and 0xFF'u32
  let g = (v shr 8) and 0xFF'u32
  let b = v and 0xFF'u32
  result = r or (g shl 8) or (b shl 16) or (235'u32 shl 24)

const
  RendAuto*    = "auto"
  RendLegacy*  = "legacy"
  RendUnified* = "unified"

proc rendererRaw*(): string =
  ## The `mapsRenderer` key exactly as it is written in config.json, so a
  ## MISSPELLING can be reported instead of silently becoming a default.
  asText(setting("mapsRenderer"), "")

proc rendererChoice*(): string =
  ## WHICH KEY SET OWNS THE SPATIAL WIDGET. A pure read; no global is touched,
  ## for the same reason readOpts touches none -- the apply path, the reconcile
  ## and the diag must all resolve this the same way or the setting becomes a
  ## control that stores and does nothing.
  ##
  ## Three values, and an unrecognised one falls back LOUDLY (the caller
  ## reports it; see rendererDecision). An ABSENT key means an OLD config that
  ## predates this setting, and for that config "auto" is the only answer that
  ## does not change what the player already had.
  let r = rendererRaw()
  if r.len == 0: return RendAuto
  case r
  of RendAuto, RendLegacy, RendUnified: r
  else: RendAuto

proc explicitOff*(): bool =
  ## THE ONE UNAMBIGUOUS "I WANT NO WIDGET" CONTROL, and it is authoritative
  ## under BOTH providers.
  ##
  ## This exists because the two providers do not express "off" the same way.
  ## `unified` has a named OFF (`spatialMode="off"`). `legacy` has none -- its
  ## off is the ACCIDENT of every surface bool happening to be false, which is
  ## indistinguishable from "this config predates the surface I care about" and
  ## is exactly the state the player fell into. So the named one is promoted to
  ## mean off everywhere, and the accidental one is no longer allowed to blank
  ## the screen on its own (see rendererOwner).
  asText(setting("spatialMode"), "") == "off"

proc legacySurfacesOn*(): bool =
  ## Does the LEGACY provider have anything switched on? Defaults match readOpts
  ## exactly (hudMap false, hudRadar true) -- two readers with two defaults is
  ## how a provider reports "I have a surface" while readOpts derives ModeOff.
  asBool(setting("hudMap"), false) or asBool(setting("hudRadar"), true)

proc unifiedSurfacesOn*(): bool =
  ## Does the UNIFIED provider have anything switched on? An unwritten or "auto"
  ## `spatialMode` is the historic default surface (radar), NEVER off -- the
  ## same rule readOpts applies. Only an explicit off, or a mode name this build
  ## does not recognise, is empty.
  let m = asText(setting("spatialMode"), "")
  if m.len == 0 or m == "auto": true
  else: modeOf(m) != ModeOff

proc rendererOwnerSelected*(): string =
  ## WHICH PROVIDER THE CONFIG NAMES, before any fall-through. `auto` resolves
  ## to unified only once `spatialMode` has actually been written; that is the
  ## migration rule and it is unchanged.
  let rend = rendererChoice()
  let modeTxt = asText(setting("spatialMode"), "auto")
  let spatialWritten = modeTxt.len > 0 and modeTxt != "auto"
  if rend == RendUnified or (rend == RendAuto and spatialWritten): RendUnified
  else: RendLegacy

proc rendererOwner*(): string =
  ## WHICH PROVIDER ACTUALLY OWNS THE WIDGET, after the EMPTY-PROVIDER
  ## FALL-THROUGH.
  ##
  ## THE BUG THIS FIXES, measured live: mapsRenderer="legacy" with hudRadar=false
  ## and hudMap=false, while spatialMode="radar" sat there fully configured. The
  ## selected provider had zero surfaces, so the widget resolved to ModeOff and
  ## the player saw nothing -- from a config in which every visible control read
  ## as "a map is configured". "The renderer ran" and "the player can see a map"
  ## are different claims and only the first was ever asserted.
  ##
  ## The rule, and it is deliberately ONE-DIRECTIONAL:
  ##
  ##   * selected provider has a surface            -> it owns the widget.
  ##   * selected provider is EMPTY, the other has  -> the other owns it, and
  ##     rendererDecision() says so by name on every apply. Blank-by-accident is
  ##     now UNREACHABLE.
  ##   * `spatialMode="off"` is set                 -> NO fall-through. An
  ##     explicit off is an instruction, not an accident, and overriding it
  ##     would leave the player with no way to hide the widget at all.
  ##   * both providers empty                       -> nothing to fall through
  ##     to; the diag reports it INCONCLUSIVE and names the disabled surfaces.
  ##
  ## Only LEGACY->UNIFIED can fire in practice, because `unifiedSurfacesOn` is
  ## false only when `spatialMode` explicitly says off -- which `explicitOff`
  ## has already excluded. The UNIFIED->LEGACY arm is kept so a future mode name
  ## that resolves empty for some other reason still cannot blank the screen.
  let sel = rendererOwnerSelected()
  if explicitOff(): return sel
  if sel == RendLegacy and (not legacySurfacesOn()) and unifiedSurfacesOn():
    RendUnified
  elif sel == RendUnified and (not unifiedSurfacesOn()) and legacySurfacesOn():
    RendLegacy
  else:
    sel

proc rendererFellThrough*(): bool =
  rendererOwner() != rendererOwnerSelected()

proc rendererSurfaces*(): string =
  ## THE ENABLED-SURFACE LIST, so a reader of one diag line can see the CAUSE of
  ## a blank widget without opening config.json. Both providers are always
  ## printed, on or off, because "the key I care about is missing from this
  ## line" and "the key is off" must not look the same.
  let m = asText(setting("spatialMode"), "")
  "surfaces: LEGACY hudRadar=" &
  (if asBool(setting("hudRadar"), true): "ON" else: "off") & " hudMap=" &
  (if asBool(setting("hudMap"), false): "ON" else: "off") &
  " -> " & (if legacySurfacesOn(): "has a surface" else: "EMPTY") &
  " | UNIFIED spatialMode=" &
  (if m.len == 0: "(unwritten -> radar)" else: "\"" & m & "\"") &
  " -> " & (if unifiedSurfacesOn(): "has a surface" else: "EMPTY") &
  " | owner=" & (if rendererOwner() == RendUnified: "UNIFIED" else: "LEGACY") &
  (if rendererFellThrough():
     " (FELL THROUGH from " &
     (if rendererOwnerSelected() == RendUnified: "UNIFIED" else: "LEGACY") &
     ", whose every surface is off)"
   else: "")

proc rendererDecision*(): string =
  ## THE DECISION, IN WORDS -- who won, what was suppressed, and why the loser
  ## is still armed. Modelled on the host's `espProvider` line, and for the same
  ## reason: a renderer that vanishes without a named reason is
  ## indistinguishable from a renderer that is broken, and the player reported
  ## exactly that.
  let raw = rendererRaw()
  let rend = rendererChoice()
  let modeTxt = asText(setting("spatialMode"), "auto")
  let spatialWritten = modeTxt.len > 0 and modeTxt != "auto"
  var pre = ""
  if raw.len > 0 and raw != rend:
    pre = "mapsRenderer = \"" & raw & "\" is not one of unified / legacy / " &
          "auto -- fell back to \"auto\". "
  elif raw.len == 0:
    pre = "mapsRenderer is ABSENT (a config written before this setting " &
          "existed), so \"auto\" is in force and nothing about this widget " &
          "changed on update. "
  # THE FALL-THROUGH, ANNOUNCED. This runs on every apply (onMapsApply logs
  # rendererDecision unconditionally), so a widget that moved provider says so
  # by name instead of appearing to ignore the setting.
  if rendererFellThrough():
    return pre & "mapsRenderer=\"" & rendererOwnerSelected() &
      "\" was SELECTED but every one of its surfaces is off, which would have " &
      "drawn NOTHING from a config that reads as fully set up -- the reported " &
      "defect. FELL THROUGH to " &
      (if rendererOwner() == RendUnified: "UNIFIED" else: "LEGACY") &
      ", which has a surface, so the widget is visible. " & rendererSurfaces() &
      ". To hide the widget deliberately set spatialMode=\"off\" (honoured " &
      "under BOTH renderers, and it suppresses this fall-through) or " &
      "enabled=false. To make the selected renderer own it again, switch one " &
      "of its own surfaces on."
  if rend == RendUnified:
    pre & "renderer=UNIFIED: `spatialMode` (=" &
    (if spatialWritten: "\"" & modeTxt & "\"" else: "unwritten -> radar") &
    ") owns the widget. SUPPRESSED: hudRadar / hudMap / radarX / radarY / " &
    "radarSize are NOT read, so no Legacy toggle can blank the map -- that " &
    "was the reported bug. The Legacy keys stay STORED and the one draw path " &
    "stays armed, so setting mapsRenderer=\"legacy\" hands them back live, " &
    "with no relaunch. To hide the widget under this renderer, set " &
    "spatialMode=\"off\" -- that is the control, not the Legacy toggle."
  elif rend == RendLegacy:
    pre & "renderer=LEGACY: hudRadar / hudMap (and radarX/Y/Size for the " &
    "geometry) own the widget. SUPPRESSED: `spatialMode` (=\"" & modeTxt &
    "\") is NOT read. Turning BOTH Legacy toggles off draws nothing, and that " &
    "is this renderer's defined behaviour rather than a fault. The unified " &
    "draw path is still armed and `spatialMode` is still stored, so " &
    "mapsRenderer=\"unified\" swaps back live."
  elif spatialWritten:
    pre & "renderer=AUTO resolved to UNIFIED because `spatialMode` has been " &
    "written (=\"" & modeTxt & "\"). SUPPRESSED: the Legacy pair is not read. " &
    "Pin mapsRenderer to \"unified\" or \"legacy\" to stop this depending on " &
    "whether one other key happens to have been written."
  else:
    pre & "renderer=AUTO resolved to LEGACY because `spatialMode` is " &
    "unwritten, so hudRadar/hudMap still own the widget -- this is the " &
    "MIGRATION path and it is the state in which turning the Legacy radar " &
    "toggle off blanks the map. SUPPRESSED: `spatialMode`. Set " &
    "mapsRenderer=\"unified\" to make that impossible."

proc readOpts(o: var HudOpts) =
  ## READS config.json into a FRESH options object and touches no global.
  ##
  ## It is a pure read on purpose. `loadHudOpts` uses it to refresh the live
  ## `gOpts`, and `mirrorDrift` uses it to work out what config CURRENTLY
  ## asks for -- so the reconcile and the apply cannot read the same keys two
  ## different ways. When they were two separate readers, every setting added
  ## to one and forgotten in the other became a control that stores and does
  ## nothing; that has cost this project five separate bugs.
  o.radar       = asBool(setting("hudRadar"), true)
  o.indicators  = asBool(setting("hudIndicators"), false)
  o.radiusM     = asFloat(setting("radiusM"), 120.0)
  o.screenW     = asFloat(setting("screenW"), 1920.0)
  o.screenH     = asFloat(setting("screenH"), 1080.0)
  o.size        = asFloat(setting("radarSize"), 220.0)
  o.x           = asFloat(setting("radarX"), 24.0)
  o.y           = asFloat(setting("radarY"), 24.0)
  o.showBots    = asBool(setting("showBots"), true)
  o.showPlayers = asBool(setting("showPlayers"), true)
  o.budgetUs    = asInt(setting("hudBudgetUs"), 400)
  o.order       = 500
  # The MAP pane. Bigger than the radar, wider span, its own toggle -- three
  # separate deliverables, three separate switches, so a player who wants the
  # radar and not a half-screen map is not forced to take both.
  o.map         = asBool(setting("hudMap"), false)
  o.mapX        = asFloat(setting("mapX"), 320.0)
  o.mapY        = asFloat(setting("mapY"), 120.0)
  o.mapSize     = asFloat(setting("mapSize"), 720.0)
  o.mapSpanM    = asFloat(setting("mapSpanM"), 500.0)
  o.mapGrid     = asInt(setting("mapGrid"), 8)
  o.indicatorInset = asFloat(setting("indicatorInset"), 48.0)
  # Indicator LIFETIME. Defaults chosen so the ramp is visible rather than a
  # blink: 0.4 s at full alpha, then 1.6 s of fade -- two seconds from the last
  # refresh to gone. Both are clamped by the schema, and a 0 fade is legal and
  # means "vanish the instant the hold elapses".
  o.indicatorHoldMs = asInt(setting("indicatorHoldMs"), 400)
  o.indicatorFadeMs = asInt(setting("indicatorFadeMs"), 1600)
  # THE FLICKER SETTING (bug 2). The feed drops a still-present contact for a
  # publish or two routinely; without this every one of those gaps dimmed the
  # mark and then snapped it back. 0 = the old behaviour, and is the control
  # that makes the fix falsifiable.
  o.indicatorGraceMs = asInt(setting("indicatorGraceMs"), 1200)
  o.heading             = asBool(setting("heading"), false)

  # ---- THE UNIFIED WIDGET's mode, and the MIGRATION of the old toggles ----
  #
  # `hudMap` and `hudRadar` were two independent switches over two overlapping
  # surfaces. `spatialMode` replaces both. An existing config has no
  # `spatialMode` key at all, and `asText(..., "")` gives "" for that case, so
  # the old pair is READ and translated -- a user who had the radar on still
  # has a radar after the update, and a user who had both on gets the MAP,
  # which is the surface that was drawn on top anyway. The translation is only
  # consulted while the key is absent; the first edit through F12 writes
  # `spatialMode` and the legacy pair stops mattering.
  # ---- THE RENDERER CHOICE (`mapsRenderer`) -------------------------------
  #
  # THE BUG THIS FIXES, in the player's words: "if i disable the legacy maps in
  # settings i see no in game map/radar". There is only ONE renderer --
  # `mhud_draw_pane_full` -- and the two Legacy-category booleans were never a
  # second renderer; while `spatialMode` read "auto" they were the widget's
  # de-facto master switch. Turning `hudRadar` off (hudMap already false)
  # resolved the mode to OFF, so the unified widget drew nothing and there was
  # nothing to "take over". `mapsRenderer` makes that ownership EXPLICIT and
  # selectable instead of implicit in whether one other key happened to be
  # written yet.
  #
  #   unified -- `spatialMode` owns the widget. The Legacy keys are NOT read
  #              at all, so no Legacy toggle can blank the map. An unwritten
  #              `spatialMode` resolves to the historic default surface
  #              (radar), NEVER to OFF: resolving to OFF here is the bug.
  #   legacy  -- the old hudMap/hudRadar pair (and radarX/Y/Size) own it, and
  #              `spatialMode` is not read. The pre-unification semantics, kept
  #              because "off by turning the radar toggle off" is what some
  #              existing configs mean.
  #   auto    -- the migration shim, and what an OLD config with no
  #              `mapsRenderer` key gets: legacy is consulted only while
  #              `spatialMode` is unwritten. Nobody's widget moves on update.
  #
  # Either way the loser is only DESELECTED, never unbound: the single draw
  # path stays armed and both key sets stay readable, so flipping this back is
  # one live apply and no relaunch.
  #
  # AND THE EMPTY-PROVIDER FALL-THROUGH (the follow-up bug). Selecting a
  # provider whose every surface is off used to resolve the widget to ModeOff
  # and draw nothing, from a config that read as fully set up. `rendererOwner`
  # -- not the raw selection -- decides here, so that state is unreachable
  # unless `spatialMode="off"` was asked for explicitly. See rendererOwner.
  let modeTxt = asText(setting("spatialMode"), "auto")
  let spatialWritten = modeTxt.len > 0 and modeTxt != "auto"
  if rendererOwner() == RendUnified:
    o.mode = if spatialWritten: modeOf(modeTxt) else: ModeRadar
  else:
    let legacyMap = asBool(setting("hudMap"), false)
    let legacyRad = asBool(setting("hudRadar"), true)
    o.mode =
      if legacyMap: (if o.heading: ModeHeadUp else: ModeNorthUp)
      elif legacyRad: ModeRadar
      else: ModeOff
    if o.mode == ModeRadar:
      # The radar had its OWN rect (radarX/radarY/radarSize). The unified widget
      # has one rect, `mapX/mapY/mapSize`, so a migrated radar takes its old
      # geometry with it -- otherwise the update would silently move the radar
      # to the map pane's corner and resize it, and the user would read that as
      # the feature breaking. Once `spatialMode` is written these three legacy
      # keys are never consulted again, and the schema says so.
      o.mapX    = asFloat(setting("radarX"), 24.0)
      o.mapY    = asFloat(setting("radarY"), 24.0)
      o.mapSize = asFloat(setting("radarSize"), 220.0)
  # `heading` still folds into the two minimap modes, so the setting a user
  # already has keeps meaning what it meant: with heading OFF a heading-up mode
  # is a north-up mode. One decision, made in one place, exactly as before.
  if o.mode == ModeHeadUp and not o.heading: o.mode = ModeNorthUp
  spatialModeSurfaces(o)         # the legacy map/radar bools, derived

  o.zoom      = asFloat(setting("zoom"), 1.0)
  o.opacity   = asFloat(setting("opacity"), 0.85)
  o.drawArt   = asBool(setting("drawArt"), true)
  o.contactPx = asFloat(setting("contactSize"), 2.0)
  o.colBot    = parseRgb(asText(setting("colorBot"), "E6463C"),
                             0xEB3C46E6'u32)
  o.colPlayer = parseRgb(asText(setting("colorPlayer"), "46BEFF"),
                             0xEBFFBE46'u32)
  o.colSelf   = 0xFFFFFFFF'u32

  # ---- PER-CONTACT-CLASS VISIBILITY AND COLOUR -------------------------
  #
  # These are REAL controls, not placeholders: `sp/world.nim` now reads
  # EPlayerSide and WildSpawnType per contact through a guarded four-hop field
  # walk (Player+0x9C0 -> Profile+0x48 -> ProfileInfo, +0x48 side / +0x78
  # Settings +0x10 role, every offset from tools/fldoff.py with its String
  # self-check passing) and publishes a class with every entity. Until that walk
  # existed these toggles WOULD have been dead controls, which is why the
  # previous pass deliberately did not ship them.
  #
  # The PMC and scav colour defaults are seeded from the EXISTING colorPlayer /
  # colorBot keys, so a config written before this build renders identically:
  # nobody's map changes colour because they took the update. `unknown` gets a
  # grey of its own -- if the Profile walk ever dies the map must LOOK wrong,
  # not quietly paint a convincing field of scavs.
  o.clsShow[ClsLocal]   = asBool(setting("showLocal"), true)
  o.clsShow[ClsPmc]     = asBool(setting("showPmc"), true)
  o.clsShow[ClsScav]    = asBool(setting("showScav"), true)
  o.clsShow[ClsBoss]    = asBool(setting("showBoss"), true)
  o.clsShow[ClsUnknown] = asBool(setting("showUnknown"), true)
  o.clsCol[ClsLocal]    = parseRgb(asText(setting("colorLocal"), "FFFFFF"),
                                   0xFFFFFFFF'u32)
  o.clsCol[ClsPmc]      = parseRgb(asText(setting("colorPmc"),
                                          asText(setting("colorPlayer"), "46BEFF")),
                                   o.colPlayer)
  o.clsCol[ClsScav]     = parseRgb(asText(setting("colorScav"),
                                          asText(setting("colorBot"), "E6463C")),
                                   o.colBot)
  o.clsCol[ClsBoss]     = parseRgb(asText(setting("colorBoss"), "FF3CDC"),
                                   0xF0DC3CFF'u32)
  o.clsCol[ClsUnknown]  = parseRgb(asText(setting("colorUnknown"), "969696"),
                                   0xC8969696'u32)

  # ---- PLACEMENT AND CHROME -------------------------------------------
  # `widgetAnchor` defaults to "manual", which is byte-for-byte the placement
  # every existing config already has: mapX/mapY as absolute top-left. Nobody's
  # widget moves because they took this build. Pick a corner and the same two
  # numbers become an inset from it, resolved against the measured back buffer.
  # LOUD ON A SPELLING WE DO NOT KNOW. `anchorOf` answers AnchorManual for a
  # typo and for the word "manual" alike, so the returned int cannot distinguish
  # "the player asked for the historical placement" from "the player asked for a
  # corner and we ignored them". `anchorRecognised` is the predicate that CAN
  # fail; the refusal names the offending text and the accepted spellings, and it
  # is emitted once per distinct bad value because readOpts is on the reconcile's
  # once-a-second path.
  let anchorText = asText(setting("widgetAnchor"), "manual")
  if not anchorRecognised(anchorText):
    if anchorText != gAnchorRefused:
      gAnchorRefused = anchorText
      warn ModName & ": REFUSED widgetAnchor=\"" & anchorText & "\" -- that is " &
           "not a spelling this build accepts, so the widget is being placed " &
           "with the historical MANUAL placement (mapX/mapY as absolute " &
           "pixels) and your corner was NOT applied. Accepted: manual, " &
           "topleft, topright, bottomleft, bottomright (hyphenated and the " &
           "two-letter forms tl/tr/bl/br also work). The placement diag line " &
           "reports the anchor actually in force."
  else:
    # Recognised again: forget the refusal so a later re-typo says so afresh.
    gAnchorRefused = ""
  o.anchor          = anchorOf(anchorText)

  # ---- THE RADAR SUB-WIDGET'S CORNER, read ONLY in `both` ---------------
  # In every other mode there is one pane and `widgetAnchor` places it. In
  # `both` the minimap and the radar are two panes and need two rects, or they
  # land exactly on top of each other. The radar's SIZE and INSET are the
  # existing radarSize/radarX/radarY keys -- those keys stop being migration-
  # only and become live geometry in this one mode, and the schema now says so
  # instead of still calling them inert.
  # Same loud-refusal contract as `widgetAnchor`: `anchorOf` cannot tell a typo
  # from the word "manual", so `anchorRecognised` is the predicate that can fail.
  let radarAnchorText = asText(setting("radarAnchor"), "manual")
  if not anchorRecognised(radarAnchorText):
    if radarAnchorText != gRadarAnchorRefused:
      gRadarAnchorRefused = radarAnchorText
      warn ModName & ": REFUSED radarAnchor=\"" & radarAnchorText & "\" -- " &
           "not a spelling this build accepts, so the radar pane of " &
           "spatialMode=\"both\" is being placed with the historical MANUAL " &
           "placement (radarX/radarY as absolute pixels) and your corner was " &
           "NOT applied. Accepted: manual, topleft, topright, bottomleft, " &
           "bottomright (hyphenated and tl/tr/bl/br also work). This key is " &
           "read ONLY in `both`; in every other mode there is one pane and " &
           "`widgetAnchor` places it."
  else:
    gRadarAnchorRefused = ""
  o.radarAnchor     = anchorOf(radarAnchorText)

  o.border          = asBool(setting("widgetBorder"), true)
  o.borderPx        = asFloat(setting("widgetBorderPx"), 2.0)
  o.backdropOpacity = asFloat(setting("widgetBackdropOpacity"), 1.0)
  # The amber square near the pane centre. Defaults TRUE, which is byte-for-byte
  # what every existing config already draws -- this switch exists so the thing
  # is NAMED and removable, not to change anyone's map underneath them.
  o.northPip        = asBool(setting("northPip"), true)

  gDrawVerdictFrames = asInt(setting("drawVerdictFrames"), 300)
  if gDrawVerdictFrames < 30: gDrawVerdictFrames = 30

  o.fsEnabled = asBool(setting("hotkeys"), false)
  o.fsKey     = asText(setting("fullscreenKey"), "M")
  o.fsMargin  = asFloat(setting("fullscreenMargin"), 48.0)
  o.fsSpanM   = asFloat(setting("fullscreenSpanM"), 1200.0)
  o.fsZoom    = asFloat(setting("fullscreenZoom"), 1.0)
  o.fsOpacity = asFloat(setting("fullscreenOpacity"), 0.92)
  o.fsNorthUp = asBool(setting("fullscreenNorthUp"), true)

  # ---- PRESS vs HOLD --------------------------------------------------
  # Loud on a spelling this build does not know, for the same reason
  # `widgetAnchor` is: `activationOfName` answers ActPress for a typo AND for
  # the word "press", so the int alone cannot tell them apart. Once per distinct
  # bad value -- readOpts is on the once-a-second reconcile path.
  let actText = asText(setting("fullscreenActivation"), "press")
  if not activationRecognisedName(actText):
    if actText != gActRefused:
      gActRefused = actText
      warn ModName & ": REFUSED fullscreenActivation=\"" & actText & "\" -- " &
           "not a spelling this build accepts, so the full-screen map key is " &
           "behaving as PRESS (a toggle) and your choice was NOT applied. " &
           "Accepted: press (also `toggle`), hold (also `held`). The " &
           "full-screen line in the maps diag names the activation in force."
  else:
    gActRefused = ""
  o.fsMode = activationOfName(actText)

  # ---- LEVEL OF DETAIL ------------------------------------------------
  # A PRESET over drawArt/mapGrid/northPip, applied here rather than in the C
  # renderer so that exactly one place decides what a preset means and the
  # offline suite can drive it. `custom` -- the default -- passes the three
  # switches through untouched, so taking this build changes nobody's map.
  let detailText = asText(setting("detail"), "custom")
  if not detailRecognisedName(detailText):
    if detailText != gDetailRefused:
      gDetailRefused = detailText
      warn ModName & ": REFUSED detail=\"" & detailText & "\" -- not a " &
           "spelling this build accepts, so the level of detail is CUSTOM " &
           "(your drawArt / mapGrid / northPip switches decide) and your " &
           "choice was NOT applied. Accepted: custom, low, medium, high."
  else:
    gDetailRefused = ""
  o.detail = detailOfName(detailText)
  let layers = resolveDetail(o.detail, o.drawArt, o.mapGrid > 0, o.northPip)
  # A preset can override a switch the player set by hand. That is by design --
  # it is what makes `high` distinguishable from `custom` -- but it must never
  # be silent, so the override is announced once per distinct resolution.
  if layers.overrode:
    let note = detailNameOf(o.detail) & " art=" & $layers.art &
               " grid=" & $layers.grid & " pip=" & $layers.pip
    if note != gDetailOverrode:
      gDetailOverrode = note
      info ModName & ": detail=" & detailNameOf(o.detail) & " OVERRODE your " &
           "layer switches -- drawArt=" & $o.drawArt & "->" & $layers.art &
           " mapGrid>0=" & $(o.mapGrid > 0) & "->" & $layers.grid &
           " northPip=" & $o.northPip & "->" & $layers.pip &
           ". Set detail=\"custom\" if you want the switches to decide."
  elif gDetailOverrode.len > 0:
    gDetailOverrode = ""
  o.drawArt  = layers.art
  o.northPip = layers.pip
  if not layers.grid:
    o.mapGrid = 0
  elif o.mapGrid <= 0:
    o.mapGrid = 8   # the preset asked for a grid; give it the shipped default

  # ---- ENEMY VISIBILITY POLICY ----------------------------------------
  # Declared so the request is NAMED, refused at read time so it is never a
  # silent no-op. See place.EnemyShootOnlyWhy for the measurement that is
  # missing; the refusal quotes it in full rather than saying "unsupported".
  let polText = asText(setting("enemyVisibility"), "always")
  if not enemyPolicyRecognisedName(polText):
    if polText != gEnemyRefused:
      gEnemyRefused = polText
      warn ModName & ": REFUSED enemyVisibility=\"" & polText & "\" -- not a " &
           "spelling this build accepts. Accepted: always, shootOnly. The " &
           "policy in force is ALWAYS."
  elif not enemyPolicyAvailable(enemyPolicyOfName(polText)):
    if polText != gEnemyRefused:
      gEnemyRefused = polText
      warn ModName & ": enemyVisibility=\"" & polText & "\" -- " &
           EnemyShootOnlyWhy
  else:
    gEnemyRefused = ""
  o.enemyPolicy = resolveEnemyPolicy(enemyPolicyOfName(polText))
  
  
  

proc loadHudOpts() =
  ## The live refresh: the same read, plus the few globals that are not part
  ## of the draw mirror (the heading gate the collector applies, and the
  ## resolved KeyCode ordinal the Unity tick polls).
  readOpts(gOpts)
  gHeadingOn   = gOpts.heading
  gFsHotkeysOn = gOpts.fsEnabled
  gFsKeyName   = gOpts.fsKey
  gFsKeyKc     = (if gOpts.fsEnabled: keycodeOf(gOpts.fsKey) else: -1)


proc spatialSchema(): seq[Setting] =
  ## `implemented` is the honest column, not a decoration. Everything declared
  ## false here names the capability that is missing, rather than being drawn as
  ## a control that does nothing.
  result = @[
    boolSetting("enabled", "Live position feed", false, category = "Feed",
                description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). Read positions on the Unity thread. OFF means " &
                              "this mod touches no game memory at all"),
    intSetting("hz", "Feed rate (Hz)", 10, lo = 1, hi = 30, category = "Feed",
               description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). How often the snapshot is published to the map page"),
    floatSetting("radiusM", "Radar radius (m)", 120.0, lo = 10.0, hi = 1000.0,
                 step = 5.0, category = "Feed",
                 description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). Anything further away than this is not drawn"),

    # ---- WHICH RENDERER DRAWS ---------------------------------------------
    enumSetting("mapsRenderer", "Map renderer", "auto",
                @["auto", "unified", "legacy"],
                category = "Widget",
                description = "WHICH KEY SET OWNS THE MAP WIDGET. There is " &
                              "exactly ONE draw path (mhud_draw_pane_full -- " &
                              "the minimap, the radar and the full-screen " &
                              "overlay are all it); this chooses which " &
                              "settings drive it, and the loser draws " &
                              "NOTHING rather than doubling up. " &
                              "unified = `Spatial widget` (spatialMode) " &
                              "owns it and the LEGACY: toggles below are not " &
                              "read at all, so none of them can blank your " &
                              "map -- if you want it hidden, set the spatial " &
                              "widget to `off`. " &
                              "legacy = the LEGACY: in-game radar / in-game " &
                              "map pair owns it (and radarX/Y/Size give the " &
                              "geometry), and `Spatial widget` is not read. " &
                              "auto = the migration shim: legacy owns it " &
                              "only until `Spatial widget` is written. " &
                              "The losing key set is only DESELECTED, never " &
                              "unbound -- the draw path stays armed and " &
                              "switching back applies live with no relaunch. " &
                              "SELECTING A RENDERER WHOSE SURFACES ARE ALL OFF " &
                              "CANNOT BLANK YOUR SCREEN: the widget FALLS " &
                              "THROUGH to whichever key set does have a " &
                              "surface, and the host log names the fall-through " &
                              "on every apply. The ONE deliberate way to hide " &
                              "the widget is `Spatial widget` = `off`, which is " &
                              "honoured under BOTH renderers and suppresses the " &
                              "fall-through (or turn the mod off entirely). " &
                              "The maps diag's `renderer` line names the " &
                              "winner, what was suppressed, WHICH SURFACES ARE " &
                              "ENABLED on both key sets, and counts the frames " &
                              "the winner actually submitted geometry on, so " &
                              "`nothing drew` can never read as a pass"),

    # ---- THE ONE SPATIAL WIDGET -----------------------------------------
    enumSetting("spatialMode", "Spatial widget", "auto",
                modeSchemaOptions(),
                category = "Widget",
                description = "ONE widget, one mode -- this replaces the " &
                              "separate `In-game radar` and `In-game map` " &
                              "toggles, which were two overlapping views of " &
                              "the same top-down projection. " &
                              "off = nothing (contacts and the full-screen " &
                              "key still work); radar = radius-culled, " &
                              "rotates with your facing, NO map art; " &
                              "northup = minimap with the baked map art, " &
                              "north at the top; headingup = the same " &
                              "minimap rotated to your facing (art included " &
                              "-- the region rotates the tiles); " &
                              "both = the minimap AND the radar at once, two " &
                              "panes in one dispatch. `both` is the ONLY mode " &
                              "that reads radarAnchor/radarX/radarY/radarSize " &
                              "as live geometry -- it needs a second rect or " &
                              "the two panes land on top of each other. " &
                              "auto = derive the mode from the old " &
                              "hudRadar/hudMap/heading keys. " &
                              "MIGRATION: while this key reads `auto` the old " &
                              "hudMap/hudRadar pair is read and translated, " &
                              "so an existing config keeps the surface it " &
                              "had. The first edit here writes the key and " &
                              "the old pair stops being consulted"),
    floatSetting("zoom", "Widget zoom", 1.0, lo = 0.25, hi = 8.0, step = 0.25,
                 category = "Widget",
                 description = "Multiplies the scale. The pane covers " &
                               "span / zoom metres, so 2.0 shows half as much " &
                               "world at twice the size. Clamped in the draw " &
                               "mirror as well as here, because config.json " &
                               "is hand-editable and a zoom of 0 would divide " &
                               "by zero on the render thread"),
    floatSetting("opacity", "Widget opacity", 0.85, lo = 0.05, hi = 1.0,
                 step = 0.05, category = "Widget",
                 description = "Scales the backdrop and the map-art tint. " &
                               "Never reaches 0: an invisible widget and a " &
                               "widget that failed to arm would look the same"),
    boolSetting("drawArt", "Draw the map artwork", true, category = "Widget",
                description = "OFF draws the grid, the player and the " &
                              "contacts and submits no textured quad at all " &
                              "-- the cheapest mode, and the one to use if a " &
                              "map's tiles are wrong. Radar mode never draws " &
                              "art regardless"),
    floatSetting("contactSize", "Contact mark size (px)", 2.0, lo = 1.0,
                 hi = 16.0, step = 0.5, category = "Widget",
                 description = "Half-extent of a contact's mark. 2.0 is the " &
                               "4x4 px dot this mod has always drawn"),
    # A real picker, not a text box. `format = "hex"` is load-bearing: the
    # reader below is `parseRgb`, which takes EXACTLY six hex digits and returns
    # the DEFAULT on anything else -- so a picker writing "0.9,0.27,0.24" here
    # would persist a value the map silently refuses. Nothing on disk changes:
    # "E6463C" is still "E6463C".
    colorSetting("colorBot", "Bot colour", "E6463C",
                  category = "Widget", format = "hex",
                  description = "Hex, with or without a leading #. A " &
                                "malformed value keeps the DEFAULT rather " &
                                "than becoming black, because a black mark on " &
                                "a dark map is indistinguishable from no mark " &
                                "at all. The diag prints the colour in force"),
    colorSetting("colorPlayer", "Player colour", "46BEFF",
                  category = "Widget", format = "hex",
                  description = "Hex, as above. `Faction` here is bot vs " &
                                "human-controlled player -- that is the only " &
                                "classification sp/world.nim measures on this " &
                                "build, so a per-side (USEC/BEAR/Scav) colour " &
                                "is not offered rather than offered and wrong"),

    enumSetting("detail", "Level of detail", "custom", detailOptions(),
                category = "Widget",
                description = "A PRESET over the three layer switches " &
                              "(`Draw the map artwork`, `Grid divisions`, " &
                              "`Draw the north pip`). " &
                              "custom -- the default -- means those three " &
                              "switches decide and this row changes nothing, " &
                              "so taking this build leaves your map exactly as " &
                              "it was. " &
                              "low draws NO artwork, NO grid and NO pip: the " &
                              "cheapest pane this renderer can submit -- " &
                              "backdrop, border, your arrow and the contacts. " &
                              "medium adds the grid and the pip but still no " &
                              "artwork (the artwork is the tile-binding path " &
                              "and the first suspect for a frame spike). " &
                              "high forces all three ON. " &
                              "NOTE THAT low/medium/high are PRESETS, not " &
                              "filters: they OVERRIDE the three switches rather " &
                              "than ANDing with them, which is what makes them " &
                              "four distinguishable outcomes instead of `high` " &
                              "being a second name for `custom`. When a preset " &
                              "overrides a switch you set by hand the host log " &
                              "says so by name, once, rather than leaving you " &
                              "to wonder why your artwork went away. " &
                              "WHAT THIS DELIBERATELY DOES NOT DO: cap the " &
                              "number of contacts drawn. The contact array has " &
                              "no distance ordering, so a cap would drop an " &
                              "ARBITRARY subset -- possibly the nearest enemy " &
                              "-- and a map that hides a contact it could have " &
                              "drawn is worse than a slower one. Use `Radar " &
                              "radius` to cut contacts by distance, which is a " &
                              "decision you can reason about"),
    enumSetting("enemyVisibility", "Show enemies", "always",
                enemyPolicyOptions(), category = "Contacts",
                implemented = false,
                description = "WHEN a hostile contact is drawn. " &
                              "always -- the default and the ONLY policy this " &
                              "build can carry out. " &
                              "shootOnly (draw a hostile only once it has " &
                              "FIRED) is NOT AVAILABLE and is REFUSED at read " &
                              "time with a named reason in the host log, not " &
                              "applied as a silent no-op: there is no shot " &
                              "signal to gate on. This mod does not consume " &
                              "mods/admin's feed at all -- it does its own " &
                              "IL2CPP walk in sp/world.nim -- and nothing in " &
                              "the repo publishes a PER-CONTACT last-fired " &
                              "time. mods/admin measures " &
                              "NewRecoilShotEffect+0x11, which is the LOCAL " &
                              "player's own weapon and cannot say whether a bot " &
                              "40 m away just fired. Implementing this needs a " &
                              "measured field offset for a bot's last-shot time " &
                              "on build 1.1.0.1.46777, and none has been taken. " &
                              "The row is declared rather than hidden so the " &
                              "request is visible and its cost is stated"),

    # ---- PLACEMENT AND CHROME -------------------------------------------
    enumSetting("widgetAnchor", "Widget corner", "manual", anchorOptions(),
                category = "Widget",
                description = "Where the widget sits. `manual` is the " &
                              "historical behaviour and the default, so " &
                              "taking this build moves nobody's widget: " &
                              "`Widget X`/`Widget Y` are the absolute " &
                              "top-left. Pick a corner and those same two " &
                              "numbers become an INSET from that corner, " &
                              "resolved every frame against the MEASURED " &
                              "back-buffer size -- so the widget holds its " &
                              "corner when you change resolution, which " &
                              "absolute pixels cannot. In a corner mode the " &
                              "result is clamped on-screen, because an " &
                              "off-screen widget and a widget that failed to " &
                              "arm look identical from the player's chair"),
    boolSetting("widgetBorder", "Draw the widget border", true,
                category = "Widget",
                description = "The 2 px frame around the pane. OFF submits no " &
                              "box at all rather than a transparent one, so " &
                              "the primitive count keeps meaning `things that " &
                              "can be seen`. Applies to the full-screen " &
                              "overlay too -- it is the same renderer"),
    boolSetting("northPip", "Draw the north pip (the small yellow dot)", true,
                category = "Widget",
                description = "The small AMBER square a short way from the " &
                              "centre of the map -- the `yellow dot in front " &
                              "of your player dot`. It marks world NORTH, not " &
                              "your heading and not a contact: with `north up` " &
                              "it is pinned to the top edge, and on a " &
                              "heading-up map it swings round as you turn, " &
                              "which is how you tell which way you are facing. " &
                              "Turn it off and no amber primitive is submitted " &
                              "at all. Applies to the minimap, the radar and " &
                              "the full-screen overlay alike -- one renderer"),
    floatSetting("widgetBorderPx", "Border thickness (px)", 2.0, lo = 0.5,
                 hi = 16.0, step = 0.5, category = "Widget",
                 description = "Clamped in the draw mirror as well as here"),
    floatSetting("widgetBackdropOpacity", "Backdrop opacity", 1.0, lo = 0.0,
                 hi = 1.0, step = 0.05, category = "Widget",
                 description = "The dark panel BEHIND the map, as a multiplier " &
                               "on `Widget opacity`. Separated from it because " &
                               "`faint box, bright map` and `faint " &
                               "everything` are different requests and one " &
                               "slider could not express both. 0 draws no " &
                               "backdrop quad at all -- the map art, grid and " &
                               "contacts float directly over the game"),

    # ---- THE FULL-SCREEN OVERLAY ----------------------------------------
    boolSetting("hotkeys", "Enable the full-screen map key", false,
                category = "Full-screen map", keybind = true,
                description = "OFF (the shipped default) means NOTHING is " &
                              "polled: no key is read, GameAssembly is not " &
                              "even looked up. ON binds " &
                              "UnityEngine.Input::GetKeyDown at a " &
                              "byte-verified RVA and reads one key per Unity " &
                              "tick. This never CAPTURES input -- it installs " &
                              "no window hook and swallows no key -- so there " &
                              "is nothing that can stay captured if it faults"),
    enumSetting("fullscreenActivation", "Full-screen map key behaviour",
                "press", activationOptions(),
                category = "Full-screen map",
                description = "HOW the key opens the map. " &
                              "press = a TOGGLE. One press opens it, the next " &
                              "one (or Escape) closes it. This is the " &
                              "historical behaviour and the default, so taking " &
                              "this build does not change how your key feels. " &
                              "It reads UnityEngine.Input::GetKeyDown, an EDGE. " &
                              "hold = the map is open exactly while the key is " &
                              "HELD and closes the frame you let go. It reads " &
                              "UnityEngine.Input::GetKey @0x531EAE0 instead -- " &
                              "a separately byte-verified RVA, and if that " &
                              "prologue does not match this build HOLD refuses " &
                              "and says so while PRESS keeps working. " &
                              "WHY HOLD IS A LEVEL READ AND NOT A DOWN/UP EDGE " &
                              "PAIR: an edge pair can miss the release and " &
                              "strand a full-screen panel over your raid. A " &
                              "level read assigns the overlay bit from the key " &
                              "every poll, so there is no state that can stick. " &
                              "Escape is not consulted in hold mode -- letting " &
                              "go already closes it. Changing this setting " &
                              "while the map is open CLOSES it, in both " &
                              "directions, so the toggle state can never be " &
                              "out of step with what you last did. The diag " &
                              "reports held frames and the open/close edge " &
                              "counts: opens > 0 with closes = 0 is an overlay " &
                              "that never came back, reported as a number"),
    keybindSetting("fullscreenKey", "Full-screen map key", "M",
                   category = "Full-screen map",
                   description = "A UnityEngine.KeyCode NAME. Press it to " &
                                 "open the full-screen map and again (or " &
                                 "Escape) to close it. Default M. An empty " &
                                 "value is UNBOUND; a name that is not a " &
                                 "KeyCode is also unbound, and the diag says " &
                                 "which of the two happened rather than " &
                                 "reporting a dead key as bound"),
    floatSetting("fullscreenSpanM", "Full-screen span (m across)", 1200.0,
                 lo = 50.0, hi = 8000.0, step = 50.0,
                 category = "Full-screen map",
                 description = "How much world the full-screen map covers " &
                               "edge to edge, before `fullscreenZoom`"),
    floatSetting("fullscreenZoom", "Full-screen zoom", 1.0, lo = 0.25, hi = 8.0,
                 step = 0.25, category = "Full-screen map"),
    floatSetting("fullscreenMargin", "Full-screen margin (px)", 48.0, lo = 0.0,
                 hi = 512.0, step = 8.0, category = "Full-screen map",
                 description = "Inset from the screen edge. The map is a " &
                               "SQUARE sized to the shorter screen axis, so " &
                               "it is never clipped on an ultrawide monitor"),
    floatSetting("fullscreenOpacity", "Full-screen opacity", 0.92, lo = 0.05,
                 hi = 1.0, step = 0.05, category = "Full-screen map"),
    boolSetting("fullscreenNorthUp", "Full-screen map is north-up", true,
                category = "Full-screen map",
                description = "ON is a wall map: north at the top whatever " &
                              "you are facing. OFF rotates it to your facing " &
                              "like the minimap. While the overlay is open " &
                              "the minimap draws NOTHING (asserted with a " &
                              "count of primitives it submitted, not with a " &
                              "claim) and the direction indicators are " &
                              "suppressed, because every contact is already " &
                              "on the map at its true position"),

    boolSetting("diagVerbose", "Verbose diagnostics (the log firehose)", false,
                category = "Feed",
                description = "OFF -- the default -- prints the full ~19-line " &
                              "diag block on the FIRST tick and then only when " &
                              "a VERDICT CHANGES, plus an all-PASS heartbeat " &
                              "every 5 minutes and a warning naming any FAIL " &
                              "or INCONCLUSIVE line every 60s for as long as " &
                              "it lasts. Nothing is hidden by this: a not-PASS " &
                              "verdict is LOUDER with it off than it was with " &
                              "it on, because it is no longer buried in a wall " &
                              "of repeated PASS. ON restores the old behaviour " &
                              "exactly -- the whole block every 2 seconds, " &
                              "which measured 40% of the entire host log."),

    boolSetting("profile", "Phase profiler", false, category = "Feed",
                description = "DEFAULT OFF, deliberately: a developer turns " &
                              "this on. It installs no detour and resolves no " &
                              "name -- two QueryPerformanceCounter reads per " &
                              "bracket -- but its OUTPUT is the expensive " &
                              "part, so see `profileVerbose` for how often it " &
                              "speaks."),
    boolSetting("profileVerbose", "Verbose phase profiler (the prof firehose)",
                false, category = "Feed",
                description = "Only read when `profile` is ON. OFF -- the " &
                              "default -- prints the full multi-kilobyte " &
                              "`maps prof:` decomposition on the first cycle, " &
                              "then every 5 minutes WHILE THE METER IS " &
                              "ADVANCING, and one line every 60s naming the " &
                              "meter as NOT ADVANCED while nothing is running " &
                              "to profile (which is the menu). The rdcache / " &
                              "entcache / entcache verdict lines print on " &
                              "CHANGE, with any FAIL or INCONCLUSIVE " &
                              "re-announced every 60s on its own line. No " &
                              "measurement is altered or softened: an " &
                              "unmeasured thing still reads NEVER RAN and a " &
                              "verdict still reads INCONCLUSIVE. ON restores " &
                              "the old ~2KB every 2 seconds, forever."),
    boolSetting("hudRadar", "LEGACY: in-game radar", true, category = "Legacy",
                description = "INERT unless `Map renderer` is `legacy` (or " &
                              "`auto` with `Spatial widget` still unwritten). " &
                              "Under the shipped `unified` renderer this key " &
                              "is NOT read and turning it off changes " &
                              "nothing -- it used to blank the map entirely, " &
                              "which is the bug `Map renderer` fixes. Use " &
                              "`Spatial widget` = off to hide the widget. " &
                              "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). Draw the radar over the game, via the shared region"),
    boolSetting("hudIndicators", "Direction indicators", false, category = "HUD",
                description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). A marker per contact, clamped to the screen " &
                              "edge in its direction. Camera-relative when the " &
                              "region has a projector installed; a NORTH-UP " &
                              "bearing ring when it does not, and the status " &
                              "line says which is happening. " &
                              "A bearing mark per contact on a ring around screen centre"),
    floatSetting("radarSize", "LEGACY: radar size (px)", 220.0, lo = 64.0,
                 hi = 640.0, step = 8.0, category = "Legacy",
                 description = "Only read while `spatialMode` is absent, to " &
                               "carry a migrated radar's geometry into the " &
                               "unified widget's `mapSize`. Inert after that"),
    floatSetting("radarX", "LEGACY: radar X (px)", 24.0, lo = 0.0, hi = 4096.0,
                 step = 4.0, category = "Legacy",
                 description = "Migration only -- see radarSize"),
    floatSetting("radarY", "LEGACY: radar Y (px)", 24.0, lo = 0.0, hi = 4096.0,
                 step = 4.0, category = "Legacy",
                 description = "Migration only -- see radarSize"),
    boolSetting("hudMap", "LEGACY: in-game map", false, category = "Legacy",
                description = "INERT unless `Map renderer` is `legacy` (or " &
                              "`auto` with `Spatial widget` unwritten) -- see " &
                              "`LEGACY: in-game radar`. " &
                              "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). A large top-down map pane drawn over the game " &
                              "by the shared region. Player-centred: anchoring " &
                              "it to the level needs the pocketmap pyramid's " &
                              "world origin, which nothing has measured"),
    floatSetting("mapSize", "Widget size (px)", 720.0, lo = 128.0, hi = 2160.0,
                 step = 16.0, category = "Widget",
                 description = "The unified widget's square, in EVERY mode " &
                               "including radar. One widget, one rect"),
    floatSetting("mapX", "Widget X (px)", 320.0, lo = 0.0, hi = 7680.0,
                 step = 8.0, category = "Widget",
                 description = "Top-left corner, pixels, origin top-left"),
    floatSetting("mapY", "Widget Y (px)", 120.0, lo = 0.0, hi = 4320.0,
                 step = 8.0, category = "Widget",
                 description = "Top-left corner, pixels, origin top-left"),
    floatSetting("mapSpanM", "Widget span (m across)", 500.0, lo = 50.0,
                 hi = 4000.0, step = 25.0, category = "Widget",
                 description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). How much world the pane covers edge to edge"),
    intSetting("mapGrid", "Grid divisions", 8, lo = 0, hi = 32,
               category = "Widget",
               description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). A scale reference, not scenery. There is no map " &
                             "ARTWORK: the region's command set is fill/box/" &
                             "line/text with no textured quad, so the " &
                             "pocketmap tiles cannot be submitted through it"),
    floatSetting("indicatorInset", "Indicator edge inset (px)", 48.0, lo = 8.0,
                 hi = 400.0, step = 4.0, category = "HUD",
                 description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). How far in from the screen edge an off-screen " &
                               "contact's marker is clamped"),
    boolSetting("showBots", "Show bots", true, category = "HUD",
                description = "The COARSE gate, kept: anything with a non-null " &
                              "Player.AIData @0xA00. ANDed with the per-class " &
                              "toggles below, never replaced by them, so each " &
                              "can independently hide a contact"),
    boolSetting("showPlayers", "Show players", true, category = "HUD",
                description = "The coarse gate for anything whose AIData reads " &
                              "null. ANDed with the per-class toggles below"),

    # ---- PER-CONTACT-CLASS CONTROLS ------------------------------------
    # Each of these is backed by a real per-contact read; see readOpts.
    boolSetting("showLocal", "Show yourself", true, category = "Contacts",
                description = "Your own marker. Class LOCAL is assigned from " &
                              "GameWorld.MainPlayer @0x230 identity, not from " &
                              "any profile read, so it is the one class that " &
                              "cannot be wrong for the reason the others can"),
    boolSetting("showPmc", "Show PMCs", true, category = "Contacts",
                description = "EPlayerSide Usec(1) or Bear(2), read from " &
                              "ProfileInfo+0x48. Includes AI PMCs (pmcBEAR 51 / " &
                              "pmcUSEC 52), which carry a real PMC side"),
    boolSetting("showScav", "Show scavs", true, category = "Contacts",
                description = "EPlayerSide Savage(4) whose WildSpawnType is not " &
                              "in the boss tier"),
    boolSetting("showBoss", "Show bosses and their guards", true,
                category = "Contacts",
                description = "WildSpawnType from ProfileSettings+0x10, matched " &
                              "against the boss/follower/sectant/raider/rogue " &
                              "values BY NUMBER (never by a substring of a name " &
                              "-- exUsec and pmcBot contain neither 'rogue' nor " &
                              "'raider'). Outranks the side, because bosses are " &
                              "Savage-sided and must not sink into the scav bucket"),
    boolSetting("showUnknown", "Show unclassified contacts", true,
                category = "Contacts",
                description = "The contact is real and its POSITION validated, " &
                              "but the Profile walk declined or the side was a " &
                              "value EPlayerSide does not define. Leave this ON: " &
                              "turning it off hides the evidence that the " &
                              "classifier is broken, and the diagnostic's class " &
                              "histogram is the only other place that shows it"),
    # Pickers, not text boxes -- the same decision as colorBot/colorPlayer
    # above, and for the same reason: every one of these is read by `parseRgb`,
    # which accepts EXACTLY six hex digits, so `format = "hex"` is what keeps
    # the picker from persisting a value its own reader would refuse. Nothing
    # on disk changes shape.
    colorSetting("colorLocal", "Colour: you", "FFFFFF", category = "Contacts",
                format = "hex",
                description = "RRGGBB. A malformed value keeps the default " &
                              "rather than becoming black"),
    colorSetting("colorPmc", "Colour: PMC", "46BEFF", category = "Contacts",
                format = "hex",
                description = "RRGGBB. Defaults to the legacy `colorPlayer` " &
                              "value when unset, so an existing config renders " &
                              "byte-identically to before this feature"),
    colorSetting("colorScav", "Colour: scav", "E6463C", category = "Contacts",
                format = "hex",
                description = "RRGGBB. Defaults to the legacy `colorBot` value " &
                              "when unset"),
    colorSetting("colorBoss", "Colour: boss", "FF3CDC", category = "Contacts",
                format = "hex",
                description = "RRGGBB"),
    colorSetting("colorUnknown", "Colour: unclassified", "969696",
                category = "Contacts", format = "hex",
                description = "RRGGBB. Deliberately a drab grey and NOT the " &
                              "scav colour: if the classifier dies the map must " &
                              "look wrong, not plausible"),
    intSetting("hudBudgetUs", "HUD draw budget (us)", 400, lo = 50, hi = 5000,
               category = "HUD",
               description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). The shared region throttles this participant if " &
                             "it overruns for 8 frames running"),

    intSetting("screenW", "Screen width (px)", 1920, lo = 640, hi = 7680,
               category = "HUD",
               description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). FALLBACK only. The region now publishes the " &
                             "measured back-buffer size and this is used only " &
                             "until it does"),
    intSetting("screenH", "Screen height (px)", 1080, lo = 480, hi = 4320,
               category = "HUD",
               description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). Only needed because the shared region does not " &
                             "yet expose the back-buffer size to a mod"),

    intSetting("indicatorHoldMs", "Indicator hold (ms)", 400, lo = 0,
               hi = 10000, category = "HUD",
               description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). How long an indicator stays at FULL opacity " &
                             "after the contact was last refreshed by the feed"),
    intSetting("indicatorFadeMs", "Indicator fade (ms)", 1600, lo = 0,
               hi = 20000, category = "HUD",
               description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). How long the indicator then takes to ramp to " &
                             "zero, after which it is REMOVED. Note what this " &
                             "does and does not fix: there is no sound feed in " &
                             "this mod, so an indicator for a contact that is " &
                             "STILL THERE never ages and never fades. This " &
                             "window governs a contact that has DROPPED OUT of " &
                             "the feed. 0 means gone the instant the hold ends"),
    intSetting("indicatorGraceMs", "Indicator absence grace (ms)", 1200, lo = 0,
               hi = 20000, category = "HUD",
               description = "How long a contact may be MISSING from the feed " &
                             "before its mark begins to fade at all. This is " &
                             "the flicker control: the feed drops a contact " &
                             "that is still standing there for a publish or " &
                             "two routinely, and without this grace every one " &
                             "of those gaps dimmed the mark and then snapped " &
                             "it back to full -- which is the blinking. A " &
                             "contact that genuinely leaves is unaffected; it " &
                             "simply fades this much later. Set 0 to reproduce " &
                             "the old blinking behaviour exactly"),

    boolSetting("heading", "Rotate radar to facing", true, category = "HUD",
                description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). Rotate BOTH the radar and the map pane to " &
                              "the player's VIEW direction, from " &
                              "MovementContext._lookDirection @0x3D0 -- the " &
                              "field EFT.Player::get_LookDirection @0x6F8060 " &
                              "reads, per its own instruction bytes. View and " &
                              "not body yaw, so the radar agrees with the " &
                              "middle of the monitor and with the direction " &
                              "indicators. OFF means north-up. If the field " &
                              "ever reads all-zero the surfaces stay north-up " &
                              "and the diagnostic says so, rather than " &
                              "rotating by a fake zero. NOTE: the region's " &
                              "textured quad is axis-aligned, so heading-up " &
                              "cannot rotate the baked ART -- the pane falls " &
                              "back to the rotating labelled grid + blips while " &
                              "rotating; turn this OFF to see the map artwork"),
    boolSetting("markers", "Loot / extract / corpse / quest markers", false,
                category = "HUD", implemented = false,
                description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). Not collected: no field offset for any of those " &
                              "lists has been measured on this build"),

    # ---- THE MARKER KINDS, one row each, each DECLARED not available -----
    #
    # These are named rather than hidden, and every one is `implemented=false`
    # for the same measured reason the umbrella `markers` row above carries: on
    # build 1.1.0.1.46777 no field offset has been taken for the loot, extract
    # or quest lists, and `sp/world.nim` does its own IL2CPP walk rather than
    # consuming another mod's feed, so there is nothing to draw from. Splitting
    # the umbrella into four rows changes NOTHING about what draws; it makes
    # the request answerable per kind and states, per kind, what is missing.
    # A silent no-op toggle would be worse than an absent one -- fact #72's
    # shape -- so none of these is offered as a working switch.
    boolSetting("markerLoot", "Marker kind: loot", false,
                category = "Markers", implemented = false,
                description = "NOT AVAILABLE on this build. Needs a measured " &
                              "field offset for GameWorld's loot item list; " &
                              "none has been taken. Turning it on stores the " &
                              "value and draws nothing, and the maps diag " &
                              "says so by name rather than pretending"),
    boolSetting("markerExtracts", "Marker kind: extracts", false,
                category = "Markers", implemented = false,
                description = "NOT AVAILABLE on this build. Needs a measured " &
                              "offset for the raid's ExfiltrationPoint list " &
                              "and its per-point world position; none has " &
                              "been taken"),
    boolSetting("markerQuests", "Marker kind: quest objectives", false,
                category = "Markers", implemented = false,
                description = "NOT AVAILABLE on this build. Needs both a " &
                              "measured offset for the active quest list and " &
                              "a world position per objective; neither has " &
                              "been taken"),
    boolSetting("markerCorpses", "Marker kind: corpses", false,
                category = "Markers", implemented = false,
                description = "NOT AVAILABLE on this build. The contact walk " &
                              "in sp/world.nim reads the ALIVE players list, " &
                              "so a corpse is not in the feed at all; this " &
                              "needs the dead list and a measured offset for " &
                              "it"),

    # ---- THE RADAR SUB-WIDGET, live geometry in `both` only -------------
    enumSetting("radarAnchor", "Radar corner (both mode)", "manual",
                anchorOptions(), category = "Widget",
                description = "Where the RADAR pane sits when spatialMode is " &
                              "`both`. manual = radarX/radarY are absolute " &
                              "pixels, which is the historical placement, so " &
                              "nobody's radar moves. Any corner turns them " &
                              "into an inset from that corner, resolved each " &
                              "frame against the measured back buffer and " &
                              "clamped on-screen. READ ONLY IN `both`: every " &
                              "other mode draws one pane, placed by " &
                              "`Widget corner`. An unrecognised spelling is " &
                              "REFUSED by name in the host log, never applied " &
                              "silently as manual"),

    # ---- THE BOUNDED DRAW VERDICT ---------------------------------------
    intSetting("drawVerdictFrames", "Draw verdict: frames before FAIL", 300,
               lo = 30, hi = 20000, step = 30, category = "Diagnostics",
               description = "How many IN-RAID dispatches may go by with a " &
                             "surface selected and NOTHING submitted before " &
                             "the maps diag calls it a FAIL instead of an " &
                             "INCONCLUSIVE. This bound is the point: without " &
                             "it `nothing has drawn yet` stays inconclusive " &
                             "forever, which is a verdict no input can " &
                             "falsify. The clock is dispatches past the " &
                             "in-raid lifecycle gate, counted by the C " &
                             "renderer, so menu frames can never spend it. " &
                             "Raise it if you load on a slow disk; it can be " &
                             "large but it may not be infinite"),
  ]

proc onMapsApply(key: string)
  ## Forward-declared so the ROUTE below can run the same hot-apply the event-bus
  ## path runs. See the comment in `onSpatialSettings`.

proc onSpatialSettings(url, body, session: string): string =
  ## THE SECOND WRITE PATH, and the one that used to lose the edit.
  ##
  ## There are two transports into this mod's settings and they were NOT
  ## symmetric:
  ##
  ##   * the event bus -- `SettingsApplyQuery` -> the SDK's `onApplyQuery`
  ##     (aowl/src/aowlspt/settings.nim:664) -> `applySettingFromBody` AND THEN
  ##     `gApplyHook(key)`, i.e. `onMapsApply`, which pushes the new visibility
  ##     into the C mirror the draw callback reads every frame.
  ##   * this ROUTE -- which called `applySettingFromBody` and stopped there.
  ##
  ## So an edit that arrived over the route was PERSISTED to config.json and
  ## never applied: `hudReconfigure` never ran, `mhud_set_enabled`/`mapOn`/
  ## `radarOn` kept whatever they held at startup, and the map went on being
  ## drawn on every frame while every config read said it was off. The store
  ## succeeded, the reply carried the new schema, and nothing on screen changed
  ## -- the exact "control that moves and changes nothing" the apply mechanism
  ## exists to prevent.
  ##
  ## The fix is to make the two transports converge on the SAME hook rather than
  ## to add a second off-switch: one predicate (`enabled`/`mapOn`/`radarOn`/
  ## `indicatorsOn` in the C mirror) still owns whether anything draws, and both
  ## write paths now drive it. `onMapsApply` is idempotent and reports its own
  ## verdict, so running it here costs one config re-read.
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
    if st == Ok:
      onMapsApply(jr.asText(jr.field(body, "key"), ""))
  result = declaredSchemaReply(st).text

# ---------------------------------------------------------------- map ART
#
# The tiles `tools/maptiles.py` produced, loaded and kept resident.
#
# WHY THE FILE IO IS ON THE UNITY TICK, when that tick's own comment says it
# does no IO. Because the alternative is worse, and the exception is bounded:
#
#   * `aowl_region_texture_define` copies into region state the RENDER thread
#     reads. Driving it from the mod's own timer thread would add a third
#     writer to that state; driving it from the Unity tick keeps it on the
#     thread the region already expects to own the CPU-side bytes.
#   * so the bytes have to arrive on this thread too, or they would be written
#     by one thread while another copied them -- a torn tile.
#
# The cost is therefore capped hard: AT MOST ONE tile file per tick. A map's
# whole layer set is at most 32 tiles of 128 KiB, so a map change costs one
# 128 KiB read per frame for under 32 frames and then nothing at all, forever.
# Nothing is re-read, nothing is allocated per frame, and the loop that finds
# the next missing tile is bounded by MA_MAX_TILES.
proc artJoin(a, b: string): string =
  ## Local, and deliberately not shared with `sp/serve.nim`'s identical helper:
  ## serve.nim is the SERVER side and this runs in the CLIENT. Importing it here
  ## would drag the whole route table into the client build for four lines.
  if a.len == 0: return b
  if a[a.len - 1] == '\\' or a[a.len - 1] == '/': return a & b
  result = a & "\\" & b

var gArtBin = ""
var gArtTried = false
var gArtRoot = ""
var gArtWhy = ""
var gArtLoaded = 0
var gArtReadFails = 0

proc artSlurp(path: string; into: var string): bool =
  ## `readFile` raises in nimony, so this is the same non-raising open/readAll
  ## pair `sp/serve.nim` uses. `fmRead` is binary on this toolchain, which is
  ## required: a text-mode read would eat 0x0D bytes out of BC1 blocks and
  ## produce art that is subtly, unfalsifiably wrong.
  into = ""
  var f: File
  try:
    if not open(f, path, fmRead): return false
  except:
    return false
  var got = ""
  var okRead = false
  try:
    got = readAll(f)
    okRead = true
  except:
    okRead = false
  try: close(f)
  except: discard
  if not okRead: return false
  into = got
  result = true

# The raid's map KEY (GameWorld.LocationId, e.g. "Woods", "bigmap",
# "factory4_day") -> the calibration FOLDER id under data/maps. This mirrors
# the `internalNames` arrays in data/maps/index.json EXACTLY; a divergence does
# not silently draw the wrong map, because the C binder REFUSES an id absent
# from the tile manifest (MA_REFUSE_MAPKEY) and REFUSES a map whose bounds do
# not contain the player (MA_REFUSE_MISMATCH). Both surface in the diag's `art`
# line. Verified against index.json on 2026-08-28. If a map is ADDED, add its
# internalNames here.
const MapKeyTable: array[13, (string, string)] = [
  ("bigmap",         "Customs_TarkovDev"),
  ("factory4_day",   "Factory_TarkovDev"),
  ("factory4_night", "Factory_TarkovDev"),
  ("sandbox",        "GroundZero_TarkovDev"),
  ("sandbox_high",   "GroundZero_TarkovDev"),
  ("interchange",    "Interchange_TarkovDev"),
  ("laboratory",     "Labs_TarkovDev"),
  ("labyrinth",      "Labyrinth"),
  ("lighthouse",     "Lighthouse_TarkovData"),
  ("rezervbase",     "Reserve_TarkovData"),
  ("shoreline",      "Shoreline_TarkovData"),
  ("tarkovstreets",  "Streets_TarkovData"),
  ("woods",          "Woods_TarkovData")]

proc lowerAscii(s: string): string =
  result = ""
  for c in s:
    if c >= 'A' and c <= 'Z': result.add chr(ord(c) + 32)
    else: result.add c

proc resolveMapId*(locKey: string): string =
  ## The raid map key -> calibration folder id, case-insensitively. "" when the
  ## key is empty or has no calibration (the caller then refuses rather than
  ## falling back to a bounds guess). Exposed for the offline acceptance check.
  if locKey.len == 0: return ""
  let k = lowerAscii(locKey)
  for pair in MapKeyTable:
    if pair[0] == k: return pair[1]
  return ""

var gArtMapKey = ""   ## last raid key we tried to resolve, for the diag

proc artTick(px, pz: float; locKey: string) =
  ## Unity's thread. Binds the map named by the raid key and feeds one tile.
  if not gArtTried:
    gArtTried = true
    gArtRoot = artJoin(artJoin(modDir(), "data"), "maptiles")
    if not artSlurp(artJoin(gArtRoot, "maptiles.bin"), gArtBin):
      gArtBin = ""
      gArtWhy = "data/maptiles/maptiles.bin is not installed -- the art is a " &
                "BUILD PRODUCT; run `aowl build maptiles` and redeploy"
      return
  if gArtBin.len == 0: return

  gArtMapKey = locKey
  let wantId = resolveMapId(locKey)
  var n = 0
  if wantId.len > 0:
    # BY KEY (bug 2): the raid tells us the map, so bind it and guard it. No
    # bounds guess, so Woods can no longer resolve to Lighthouse.
    n = artBindId(gArtBin, wantId, px, pz)
  else:
    # No raid key (unreadable, or a map with no calibration). Fall back to the
    # old smallest-area bounds heuristic, which is a labelled GUESS in the diag.
    n = artBindAt(gArtBin, px, pz)
  if n <= 0: return

  var i = 0
  while i < n and i < 32:          # capped by construction, never by the file
    if not artTileHave(i):
      let rel = artTileFile(i)
      var raw = ""
      if artSlurp(artJoin(gArtRoot, rel), raw):
        if artGiveTileDds(i, raw):
          inc gArtLoaded
          gArtWhy = ""
        else:
          inc gArtReadFails
          gArtWhy = "tile " & rel & " was read but REFUSED: its payload is " &
                    "not the " & $artTileLen() & " bytes the manifest declares"
      else:
        inc gArtReadFails
        gArtWhy = "tile file could not be read: " & rel
      break                        # exactly ONE file per tick
    inc i
  discard artUpload()

proc onMainTick(payload: string): string =
  ## Unity's thread. Raw guarded reads into a preallocated buffer, and nothing
  ## else: no formatting, no file IO, no allocation beyond the bounded id
  ## labels. Everything expensive is the publish tick's job.
  if not gEnabled: return ""
  inc gTicks
  # L0. The whole body, so every L1 phase can be summed against something it did
  # not itself produce and the remainder named as UNEXPLAINED rather than
  # silently attributed. mpNow()/mpAdd are no-ops when the profiler is off.
  let tWhole = mpNow()
  mpControl()
  let tLock = mpNow()
  lockMod()
  mpAdd(MpLock, tLock)
  let tColl = mpNow()
  collect(gSnap)
  mpAdd(MpCollect, tColl)
  gPending = true
  # The `heading` setting gates the ROTATION, not the measurement: the
  # heading is still read and still counted every collection, so
  # `mapsDiagText` can report whether it is live and MOVING even while the
  # surfaces are deliberately north-up. Gating the read instead would make
  # "the setting is off" and "the field is dead" produce the same diagnostic,
  # which is the ambiguity this mod keeps paying for.
  if not gHeadingOn: gSnap.hasHeading = false
  let tPub = mpNow()
  if gHudOn: hudPublish(gSnap)   # same thread as the region's draw; see sp/hud.nim
  mpAdd(MpPublish, tPub)
  # THE FULL-SCREEN MAP KEY. Unity's thread, which is where
  # `Input::GetKeyDown` belongs and the only thread it is ever called from. With
  # `hotkeys` off or the key unbound this is one compare and NOTHING is called
  # -- not GetModuleHandle, not the game method -- which is the shipped state.
  #
  # It is polled here rather than on the publish timer for two reasons: that
  # timer is not Unity's thread, and this tick is already gated on `enabled`, so
  # a disabled feature cannot open a panel over the player's raid.
  let tFs = mpNow()
  if gHudOn and gFsHotkeysOn and gFsKeyKc >= 0:
    discard hudFsPoll(gFsKeyKc, true)
  elif hudFsOpen():
    # The key was just turned off (or unbound) while the overlay was OPEN. Close
    # it, on the tick that notices, rather than leaving a full-screen panel the
    # player now has no key to dismiss. This is the fault path too: if the poll
    # ever stops running for any reason, the overlay does not outlive it.
    hudFsClose()
  mpAdd(MpFsPoll, tFs)
  let tArt = mpNow()
  # The ART, on the same thread and after the mirror is filled. Gated on a
  # VALIDATED local position: binding a map from a position that failed
  # `mm_pos_classify` would pick a map by a number we already know is wrong.
  # Gated on an ACTIVE RAID (bug 1), not merely a validated pose: a stale
  # borrowed GameWorld cache in the menu can validate a pose but is not a raid,
  # and binding art there would upload tiles and paint an overlay off-raid.
  # Only the MAP and RADAR panes render art; gate the tile IO/upload on one of
  # them being on (bug 4). An indicator-only or all-off config used to slurp and
  # upload a tile per tick for a surface nothing drew.
  # The tile IO/upload is gated on a surface that can actually SHOW art: a
  # minimap mode, or the full-screen overlay being available. Radar mode draws
  # no art by construction and `drawArt` off asks for none, so neither slurps a
  # tile per tick for something nothing draws.
  if gHudOn and gOpts.drawArt and
     (gOpts.map or (gOpts.fsEnabled and gFsKeyKc >= 0)) and
     activeRaid(gSnap) and gSnap.localIdx >= 0 and gSnap.localIdx < gSnap.n:
    artTick(gSnap.ents[gSnap.localIdx].x, gSnap.ents[gSnap.localIdx].z,
            gSnap.locationId)
  mpAdd(MpArt, tArt)
  unlockMod()
  mpAdd(MpWhole, tWhole)
  mpTick()
  result = ""

var gClsHistLast = ""
  ## Last histogram line EMITTED, so the log carries one line per change rather
  ## than one per publish tick. "" also means "no raid line is outstanding",
  ## which is what makes the raid-ended line fire exactly once.

proc onPublishTick(payload: string): string =
  ## The mod's own timer thread. Formatting and file IO live here and only here.
  if not gEnabled: return ""
  lockMod()
  let have = gPending
  gPending = false
  var body = ""
  var hist = ""
  var inRaidNow = false
  if have:
    body = snapshotJson(gSnap, feedStateText(), feedDefect(), feedFaults(),
                        feedDisabled(), gRadius)
    hist = clsHistogramText(gSnap.cls)
    inRaidNow = activeRaid(gSnap)
  unlockMod()

  # THE PER-RAID CLASS HISTOGRAM. Emitted on CHANGE while an active raid is in
  # progress, and once more when the raid ends carrying the last live figures,
  # so a session that never opened the diag page still has the numbers in the
  # host log. It is deliberately the raw distribution and not a verdict: the
  # verdict (clsVerdict) is printed beside it, and a reader who disagrees with
  # the verdict can check it against the counts in the same line.
  if inRaidNow and hist != gClsHistLast:
    gClsHistLast = hist
    info ModName & ": " & hist & "  " & clsVerdict()
  elif (not inRaidNow) and gClsHistLast.len > 0:
    info ModName & ": raid ended -- last " & gClsHistLast & "  " & clsVerdict()
    gClsHistLast = ""

  if not have: return ""
  var err = ""
  if writeSnapshot(body, err):
    inc gPublished
  else:
    gLastErr = err
  result = ""

# --------------------------------------------------------------------------
# THE DIAGNOSTIC. This mod's most important output.
# --------------------------------------------------------------------------
#
# The bug this exists for: on 2026-08-28 a human reported "no in-game radar",
# and the mod had said NOTHING for the whole session -- it announced a
# successful registration at load and was then silent forever. Every part was
# working except one, and the one that was not had no voice:
#
#   * region ARMED, participant 'maps.hud' registered   (host log, measured)
#   * config enabled/hudRadar/hudIndicators all true    (config.json)
#   * GameWorld live, in a raid                         (snapshot state:"live")
#   * ...and `ok:false localIdx:-1 ents:[] faults:0 defect:"none"`
#
# `mhud_draw` was returning at `if (!hasLocal) return;` on every single frame,
# forever, silently, because `posOf` rejected every player and recorded no
# reason. A feature that declines silently is the worst outcome we produce
# (CLAUDE.md 6), so this tick makes that impossible: it reports every stage,
# every time, and each stage is PASS, FAIL or INCONCLUSIVE -- never a bare
# two-way "working / not working", because "I could not look" is not a pass
# (CLAUDE.md 9b).
#
# It is NOT gated on anything being wrong: the first tick always prints. After
# that it prints only when the text CHANGES, plus a heartbeat, so a healthy
# session costs a handful of lines and a broken one cannot hide.

var gDiagRep = DiagRepeatState(sig: "", quiet: 0'i64, lastPhase: -1, announced: false)
  ## The repeat policy's WHOLE state: the last VERDICT SIGNATURE (see
  ## diagfilter.nim, NOT the last block text -- holding the text here is what
  ## made the change-detection a check that could not fail, since the text
  ## carries counters and therefore always differed), how many cycles it has
  ## stood, and which host phase the standing not-PASS was last announced under.
  ## `diagStep` is the only thing that reads or writes it, and it is pure.
var gDiagTicks = 0'i64
var gDiagVerbose = false
  ## The `diagVerbose` setting. DEFAULT FALSE. True restores the old behaviour
  ## exactly: the whole block, every tick, unconditionally.

var gProfVerbose = false
  ## The `profileVerbose` setting. DEFAULT FALSE. Same convention, and the same
  ## reason, as `diagVerbose`: ON restores the old behaviour byte-for-byte (the
  ## multi-kilobyte `maps prof:` block plus the three cache lines, every 2s
  ## forever). OFF does not suppress a single MEASUREMENT -- every string below
  ## is still produced by the same functions, verbatim -- it only decides when
  ## to REPEAT one.
var gProfCycles = 0'i64
  ## Diag cycles seen while the profiler was enabled. Cycle 1 always prints.
var gProfLastTicks = -1'i64
  ## `mpTicks()` at the previous cycle. Unchanged means the meter recorded
  ## NOTHING new -- which at the menu is the whole of the problem: kilobytes to
  ## report that nothing ran.
var gProfIdle = 0'i64
  ## Consecutive cycles on which `mpTicks()` did not advance.
var gCacheLast = ""
  ## Verdict signature of the three cache lines (rdcache / entcache / entcache
  ## verdict), via the SAME `diagSignature` the diag block uses, so the counters
  ## inside a steady verdict cannot make change-detection a check that always
  ## fires.
var gCacheQuiet = 0'i64

proc mapsDiagText(): string =
  ## Assembled from the FINISHED state -- the counters the collector and the
  ## draw callback actually accumulated -- not from "the call was made".
  let tried = posEverTried()
  let good  = posEverGood()
  let st    = gwState()

  # The raid-lifecycle fields live in gSnap, which the Unity thread rewrites
  # under lockMod; copy them here under the same lock so the diag thread never
  # reads a torn string. `hudInRaid()` reads the C mirror and needs no lock.
  lockMod()
  let diagInRaid = hudInRaid()
  let diagActive = activeRaid(gSnap)
  let diagRaidWhy = activeRaidWhy(gSnap)
  let diagLocKey = gSnap.locationId
  unlockMod()

  # 1. the shared region: is anything dispatching us at all?
  var lRegion = ""
  # WHY THIS IS NOT ONE `not gHudOn` BRANCH ANY MORE.
  #
  # It was, and it printed a single FAIL asserting "radar, map and indicators
  # are all off in config.json". MEASURED on the 2026-09-04 run (build
  # 6bd304e3): the live config held `spatialMode=radar` with `enabled=false`, so
  # that sentence was false in every clause while the real cause -- the master
  # switch -- went unnamed. A verdict that states an unmeasured cause is worse
  # than no verdict, and a deliberately-disabled feature is not a FAIL at all.
  #
  # So the absence of a participant now resolves through the state that was
  # actually recorded, in the order the code takes it, and only the last case is
  # a failure:
  #   * `gHudTried=false`  -- onLoad returned at the `enabled=false` gate and
  #     registration was NEVER ATTEMPTED. Deliberate; INCONCLUSIVE, and it names
  #     the key and the one-line remedy.
  #   * tried, no surface   -- armFeed reached the decision and declined because
  #     every spatial surface is off. Deliberate; INCONCLUSIVE, and it names
  #     WHICH surfaces it read, so the reader can check them.
  #   * tried, surface on, `gHudRefusal` set -- the region genuinely said no.
  #     FAIL, quoting the refusal the region itself produced.
  # The raid phase is reported alongside, because "no participant" while
  # DEPLOYED is the case the user is complaining about and it must not read the
  # same as "no participant at the menu".
  let rgPhase = hostPhase()
  let rgInRaid = rgPhase == RpDeployed
  let rgWhere = (if rgInRaid: " -- and the host phase is DEPLOYED, so this is " &
                              "exactly the in-raid frame that should be drawing"
                 else: " (host phase is not DEPLOYED, so nothing would be " &
                       "drawing yet regardless)")
  let rgSurfaces = "spatialMode=" & modeName(gOpts.mode) &
                   " indicators=" & $gOpts.indicators &
                   " fullscreenKey=" & (if gFsKeyKc >= 0: gFsKeyName
                                        else: "(unbound)")
  if not gHudOn:
    if not gHudTried:
      lRegion = "INCONCLUSIVE  no draw participant, and registration was never " &
                "ATTEMPTED: config.json `enabled` is false, so onLoad returned " &
                "before arming. This is the master switch, NOT the surface " &
                "keys -- they currently read " & rgSurfaces & ". Set " &
                "`enabled` true (F12 late-arms it in place, no relaunch) and " &
                "watch for 'maps: LATE ARM'" & rgWhere
    elif gHudRefusal.len > 0:
      lRegion = "FAIL  the missing participant is 'maps.hud': registration was " &
                "attempted and the shared region REFUSED it -- " & gHudRefusal &
                ". Surfaces read " & rgSurfaces & rgWhere
    else:
      lRegion = "INCONCLUSIVE  no draw participant, and registration was " &
                "attempted but DECLINED by this mod because every spatial " &
                "surface is off: " & rgSurfaces & ". Set `spatialMode` to " &
                "radar/map, or `indicators` true, or bind the full-screen key" &
                rgWhere
  elif not hudArmed():
    lRegion = "FAIL  registered, but the region is NOT armed, so the draw " &
              "callback can never fire. Set host flag `sharedRegion`"
  elif hudFrames() <= 0'i64:
    lRegion = "INCONCLUSIVE  registered and armed, but ZERO frames have been " &
              "dispatched to us yet -- nothing has called us even once"
  elif rgInRaid and hudDrawn() <= 0'i64:
    # DISPATCH IS NOT DRAW. `hudFrames` counts times the region CALLED us;
    # `hudDrawn` counts frames on which the callback actually submitted the
    # pane. While the host phase is DEPLOYED those must not read the same:
    # a callback that is invoked every frame and returns early at its master
    # gate would otherwise PASS this line forever while the screen is empty,
    # which is precisely a check that cannot fail. Only the in-raid case is
    # judged, because outside a raid drawing nothing is correct.
    lRegion = "FAIL  participant 'maps.hud' IS registered and armed and has " &
              "been dispatched " & $hudFrames() & " frame(s), but it has drawn " &
              "on ZERO of them while the host phase is DEPLOYED -- the " &
              "callback is being called and is returning before it submits a " &
              "pane. " & $hudGated() & " dispatch(es) were gated off, " &
              $hudMasked() & " masked. Surfaces read " & rgSurfaces
  else:
    lRegion = "PASS  armed, " & $hudFrames() & " frame(s) dispatched to us, " &
              $hudDrawn() & " of them drawn (" & $hudBlips() & " blip(s))" &
              (if rgInRaid: " with the host phase DEPLOYED"
               else: " -- host phase is not DEPLOYED, so a zero draw count " &
                     "here is correct and this PASS covers dispatch only")

  # 2. the world: is there a raid, and can we see it?
  var lWorld = ""
  case st
  of 0: lWorld = "FAIL  no host export aowl_host_gameworld -- this host is too old"
  of 1: lWorld = "INCONCLUSIVE  the host exports the world but NO detour is " &
                 "armed to populate it. Set host flag `debugEsp` or `botDiag`. " &
                 "This is NOT 'you are not in a raid'"
  of 2: lWorld = "INCONCLUSIVE  armed, no GameWorld cached -- consistent with " &
                 "being in the menu, but it is not proof of it"
  else: lWorld = "PASS  GameWorld live (borrowed from the host's RegisterPlayer cache)"

  # 2b. THE RAID LIFECYCLE GATE (bug 1), stated as its OWN line and never folded
  # into `world` above. `world PASS` means only that the borrowed RegisterPlayer
  # cache is non-null -- which fact #141 says is true ~15s BEFORE the player
  # deploys, in the menu, and after extract. The HUD must NOT draw then. This
  # line reports `activeRaid()` -- state 3 AND a validated local pose AND the
  # local player present in the live AllAlivePlayersList (the game's own
  # spawned-and-in-world set) -- so a reader can tell "world is cached" apart
  # from "I have actually spawned into the raid". It is the finished-state gate
  # the draw/publish/art paths all consult; naming it here makes visible WHICH
  # condition opened or closed it.
  # 2a. THE THREE LIFECYCLE SITUATIONS, separately visible and separately
  # falsifiable. The `raid` line below reports the mod's OWN gate; this line
  # reports the host's phase latch, which is what now drives the draw. They are
  # printed separately on purpose: on 2026-08-30 `raid` read CLOSED while the
  # map was visibly on the results screen, and one merged line would have hidden
  # exactly that disagreement.
  let lPhaseV = hostPhase()
  var lPhase = ""
  case lPhaseV
  of RpNoExport:
    lPhase = "INCONCLUSIVE  the host does not export `aowl_host_raid_phase` -- " &
             "it predates this gate, or this is the SERVER side of the mod. The " &
             "draw falls back to the old world-existence behaviour, so a stale " &
             "map on the results screen is EXPECTED against this host, not fixed."
  of RpUnknown:
    lPhase = "INCONCLUSIVE  the host looked and could not tell: either nothing " &
             "is armed to populate the GameWorld cache (set host flag debugEsp " &
             "or botDiag) or its guarded tick faulted. The draw is NOT blanked " &
             "on this -- 'I could not look' must not black out a live raid."
  of RpLoading:
    lPhase = "PASS (a) SCENE LOADING -- a GameWorld exists because bots are " &
             "registering, but the player is NOT deployed (Camera.main null, or " &
             "MainPlayer absent from AllAlivePlayersList). The mirror is being " &
             "committed EMPTY, so the widget and the overlay are dark."
  of RpDeployed:
    lPhase = "PASS (b) DEPLOYED -- the host latched on a positive deploy " &
             "observation and holds through the MainPlayer null flicker. The " &
             "mirror is being committed with a live centre; overlays draw."
  of RpResults:
    lPhase = "PASS (c) RESULTS SCREEN -- SceneManager lists SessionEndUIScene " &
             "and/or Camera.main is null while the GameWorld cache is STILL " &
             "non-null. The mirror is being committed EMPTY, so the held frame " &
             "is dropped and nothing draws over the results."
  of RpMenu:
    lPhase = "PASS  MENU -- no GameWorld cached; the mirror is committed empty."
  else:
    lPhase = "FAIL  the host returned phase=" & $lPhaseV & ", which is not one " &
             "of the values raidphase.nim defines. Do not trust the gate."

  var lRaid = ""
  if diagActive:
    lRaid = "PASS  gate OPEN -- the local player is in the live " &
            "AllAlivePlayersList (spawned, in-world this frame); HUD draws"
  else:
    lRaid = "CLOSED  HUD idle -- " & diagRaidWhy

  # 3. positions. THE stage that was silent. Never collapses to a bool.
  var lPos = ""
  if st != 3:
    lPos = "INCONCLUSIVE  not attempted -- there is no live world to read"
  elif tried == 0:
    lPos = "INCONCLUSIVE  a world is live but ZERO position reads were " &
           "attempted -- the player list was empty or unreadable"
  elif good == 0:
    lPos = "FAIL  " & posVerdict() & " [" & posEverText() & "]"
  else:
    lPos = "PASS  " & $good & " of " & $tried & " position read(s) validated " &
           "[" & posEverText() & "]"

  # 4. the draw itself, asserted on the FINISHED state: did primitives come
  # out, AND was anything ever supposed to come out. The ladder is in
  # `diagfilter.drawVerdict` -- pure, and driven by tests/mapsdiag.nim -- because
  # this check used to read FAIL at the MAIN MENU, where 0 draws is correct
  # behaviour and its negative could not be distinguished from "not in a raid".
  let lDraw = drawVerdict(gHudOn, hudArmed(), hudFrames(), hudDrawn(),
                          hudBlips(), hudMasked(), hudGated(),
                          diagActive, diagRaidWhy)

  # 5. the back buffer. A 0x0 screen puts every mark in the corner.
  var lScreen = ""
  if hudScreenMeasured() != 0'i32:
    lScreen = "PASS  " & $hudScreenW() & "x" & $hudScreenH() &
              " (measured back buffer)"
  else:
    lScreen = "INCONCLUSIVE  the region has not published a back-buffer size; " &
              "using the config fallback " & $hudScreenW() & "x" &
              $hudScreenH() & ". Edge-anchored marks may be misplaced"

  # 6. THE PROJECTOR -- a map, or merely a radar.
  #
  # This line used to have one useful outcome and two spellings of "no". It now
  # has three, and the PASS is not a restatement of our own call.
  #
  # The trap being avoided is specific and has been paid for before: a
  # view-projection that is transposed, multiplied in the wrong order, or read
  # row-major from a column-major buffer is FINITE and NON-ZERO. Every contact
  # still "projects"; they simply all land somewhere absurd. A count of
  # projections would climb through all of that and report PASS. So the verdict
  # is driven by the FINISHED COORDINATES read back out of the draw path --
  # `indOnScreen` (in front of the camera AND inside the frame) and the last
  # measured depth -- neither of which this mod can satisfy by writing them.
  #
  # And the behind-camera flag is part of the PASS rather than a footnote: it is
  # the falsifier. If a projector is installed and NOTHING is ever behind the
  # player, either nothing is being told or the depth sign is wrong.
  var lProj = ""
  let projLive = hudProjValid() != 0'i32
  if projLive and hudIndOnScreen() > 0'i64:
    lProj = "PASS  a projector IS installed and it is producing real screen " &
            "positions: " & $hudIndOnScreen() & " contact(s) projected IN " &
            "FRONT and inside the frame, " & $hudIndBehind() &
            " rejected as BEHIND the camera (drawn as a mirrored bearing, " &
            "which is correct), " & $hudIndProjected() &
            " indicator(s) drawn in total. Last finished projection " &
            $hudProjLastX() & "," & $hudProjLastY() & " px at depth " &
            $hudProjLastDepth() & " m -- read back off the draw path, not " &
            "asserted"
  elif projLive:
    lProj = "FAIL  a projector is installed and returned coordinates, but " &
            "NOT ONE contact landed in front of the camera inside the frame " &
            "(" & $hudIndBehind() & " behind, " & $hudIndProjected() &
            " drawn). Last finished projection " & $hudProjLastX() & "," &
            $hudProjLastY() & " px at depth " & $hudProjLastDepth() &
            " m. That is the classic WRONG-MATRIX symptom -- a transposed " &
            "view-projection, or P*V multiplied the other way round, is " &
            "finite and non-zero and throws everything off-screen. The " &
            "bearing-ring fallback is still selectable, so the display " &
            "degrades rather than blanks"
  elif hudIndBearing() > 0'i64:
    lProj = "INCONCLUSIVE  " & $hudIndBearing() & " indicator(s) drawn as " &
            "BEARING RINGS; no projector is installed, so they are a bearing " &
            "and not a projected screen position. The host installs one from " &
            "the region's per-frame tick behind the `regionProjector` flag " &
            "(python tools/hostcfg.py set regionProjector on, and " &
            "sharedRegion must be on too); with the flag off this is the " &
            "expected state, not a fault. They are no longer NORTH-UP " &
            "whenever a heading was measured -- the ring takes the same " &
            "rotation the radar does -- so a turning player now turns them; " &
            "see `heading` below for whether that is actually happening"
  else:
    lProj = "INCONCLUSIVE  no indicator has been drawn yet, so neither the " &
            "projector nor the bearing-ring fallback has been exercised. " &
            "This is 'I could not look', which is not a pass"

  # 7. the HEADING. Defect 1: "the player rotation does not rotate either map."
  # The trap this line exists to avoid is reporting PASS for a heading that
  # reads perfectly and never changes -- which draws a map that never rotates
  # and is indistinguishable from a working one on any single sample. So the
  # verdict is driven by the number of TURNS observed, not by the number of
  # successful reads. `hdgVerdict` owns that; this line adds only whether the
  # setting is even on, because "off" and "dead" must never look alike.
  var lHdg = ""
  if not gHeadingOn:
    lHdg = "INCONCLUSIVE  the `heading` setting is OFF, so both surfaces are " &
           "deliberately north-up. The measurement still ran: " & hdgVerdict()
  else:
    lHdg = hdgVerdict()

  # 8. indicator LIFETIME. Defect 2: "the audio indicators always stay on the
  # screen." The honest finding is stated first and unconditionally, because
  # the fade cannot make these into audio cues and a diagnostic that implied
  # otherwise would be the confidently-wrong-answer failure all over again.
  var lLife = ""
  if hudTracks() == 0 and hudIndExpired() == 0'i64:
    lLife = "INCONCLUSIVE  no contact has ever been tracked, so the decay has " &
            "not been exercised"
  elif hudIndExpired() == 0'i64:
    lLife = "INCONCLUSIVE  " & $hudTracks() & " contact(s) tracked and none " &
            "has expired yet. That is EXPECTED while every contact is still " &
            "in the feed: an indicator only ages once the feed STOPS " &
            "refreshing it"
  elif (hudIndFadedDrawn() + hudPaneGhostsFaded()) == 0'i64 and hudFadeMs() == 0:
    # A ZERO FADE WINDOW IS A SETTING, NOT A DEFECT. mm_fade_alpha returns 1.0
    # up to the hold and 0.0 immediately after it, so no primitive at reduced
    # alpha can EXIST. Reporting FAIL here would be a verdict on the player's
    # own configuration, and it is exactly the shape §9b forbids: a check whose
    # negative outcome was decided by something other than the code under test.
    lLife = "INCONCLUSIVE  indicatorFadeMs is 0, so there is no ramp by " &
            "construction: full alpha for " & $hudHoldMs() & "ms, then gone. " &
            $hudIndExpired() & " track(s) were evicted, and NO faded primitive " &
            "could ever be submitted at this setting. Raise indicatorFadeMs " &
            "above 0 to exercise the decay"
  elif (hudIndFadedDrawn() + hudPaneGhostsFaded()) == 0'i64 and
       not hudLiveIndicators() and hudLiveMode() == 0:
    # BOTH consumers of the decay are switched OFF -- the edge indicators by
    # `indicators`, the ghost blips by the widget being in mode OFF. A switched
    # off feature is INCONCLUSIVE, never FAIL: nothing could have faded, so
    # nothing failed to. (This line used to report FAIL with hudIndicators
    # false, which is a verdict no input could have changed.)
    lLife = "INCONCLUSIVE  both surfaces that consume the decay are OFF " &
            "(indicators=off, widget mode=off), so nothing could fade. " &
            $hudIndExpired() & " track(s) still aged out correctly; the " &
            "indicator loop declined " & $hudIndGatedOff() & " visit(s) at " &
            "the on/overlay gate"
  elif (hudIndFadedDrawn() + hudPaneGhostsFaded()) == 0'i64 and
       hudIndVisits() == 0'i64 and hudGhostVisits() == 0'i64:
    # (a) The loops were never entered for a live track. Distinct from "entered
    # and culled" and from "computed and thrown away", which is the whole point
    # of the three counters.
    lLife = "INCONCLUSIVE  neither the indicator loop nor the pane ghost loop " &
            "was entered for a single live track (indVisits=0, ghostVisits=0), " &
            "so no decay could be computed. The draw itself is what did not " &
            "run over these tracks -- look at the gate counters, not at the fade"
  elif (hudIndFadedDrawn() + hudPaneGhostsFaded()) == 0'i64:
    # THE CHECK THAT CAN FAIL (Â§9b). It asks the FINISHED STATE -- was a region
    # command actually SUBMITTED carrying a reduced alpha -- not whether a decay
    # value was computed. `hudIndFaded()` is the computed count and is printed
    # only as context; using it as the verdict is what made this pass while
    # contacts popped out on screen, because every cull between the calculation
    # and the fill threw the faded colour away.
    lLife = "FAIL  " & $hudIndExpired() & " track(s) were evicted and NOT ONE " &
            "faded primitive was ever SUBMITTED (pane ghosts=" &
            $hudPaneGhosts() & ", of them faded=" & $hudPaneGhostsFaded() &
            "; indicators submitted faded=" & $hudIndFadedDrawn() &
            "; decay COMPUTED " & $hudIndFaded() & " time(s)). A computed " &
            "alpha that never reaches a fill is the defect: contacts are " &
            "disappearing abruptly instead of fading" &
            # WHERE the control flow actually stopped. These four used to
            # collapse into the single zero above, which is why three sessions
            # read "the decay never runs" and could not say why.
            ". WHERE IT STOPPED: indicator loop visited " & $hudIndVisits() &
            " live track(s), declined " & $hudIndGatedOff() &
            " at the on/overlay gate and " & $hudIndFiltered() &
            " at the bot/player filter, and REACHED mm_fade_alpha " &
            $hudIndAlphaCalc() & " time(s); the pane ghost loop saw " &
            $hudGhostVisits() & " track(s) out of the feed, of which " &
            $hudGhostZero() & " were ALREADY past hold+fade the first time it " &
            "looked. Blackout rebases=" & $hudRebases() & " (" &
            $hudRebasedTracks() & " track stamp(s) moved, worst gap " &
            $hudRebaseMsMax() & "ms) -- a high ghostZero with rebases at 0 " &
            "means the draw was starved while the clock ran; alphaCalc high " &
            "with submitted at 0 means the culls below the calculation are " &
            "eating it"
  else:
    lLife = "PASS  " & $hudPaneGhostsFaded() & " pane contact(s) and " &
            $hudIndFadedDrawn() & " indicator(s) were SUBMITTED at reduced " &
            "alpha (of " & $hudPaneGhosts() & " ghost draw(s)), and " &
            $hudIndExpired() & " track(s) were removed after their window (" &
            $hudHoldMs() & "+" & $hudFadeMs() & "ms); " & $hudTracks() &
            " track(s) live"
  lLife = lLife & ". NOTE: these are NOT audio indicators. This mod " &
          "subscribes to no sound event of any kind; every indicator is one " &
          "live entry of GameWorld.AllAlivePlayersList, refreshed every " &
          "collection. An indicator that persists for a contact that is still " &
          "present is the FEED working as built, not a failed decay"

  # 6b. THE FLICKER VERDICT (bug 2). The line above cannot answer the user's
  # actual question -- "why does it blink?" -- because reduced-alpha
  # submissions are consistent with BOTH explanations. This one separates them
  # and is the falsifiable negative the fix has to be judged against:
  # NO track for a still-present contact was removed and re-added.
  var lFlick = ""
  if hudTracks() == 0 and hudIndExpired() == 0'i64:
    lFlick = "INCONCLUSIVE  no track has ever been created, so nothing could " &
             "have been re-created. This is 'I could not look', not a pass."
  elif hudRecreated() > 0'i64:
    lFlick = "FAIL  " & $hudRecreated() & " track(s) were EVICTED and then " &
             "re-claimed for the SAME identity within 3000ms. That is not a " &
             "fade -- the mark went out and popped back in, so the flicker is " &
             "IDENTITY CHURN and the grace window is not the fix for it. " &
             "(" & $hudRecreatedLate() & " later re-claim(s), which are " &
             "genuine re-entries and are NOT counted as churn.)"
  else:
    lFlick = "PASS  ZERO tracks were evicted and re-claimed for the same " &
             "identity within 3000ms (" & $hudRecreatedLate() & " genuine " &
             "re-entr(ies) after that window, which are not flicker). The " &
             "blink was therefore ALPHA OSCILLATION, not identity churn, and " &
             "the absence grace is the fix for it: " & $hudGraceHeld() &
             " mark(s) that the old code would have dimmed were held at FULL " &
             "alpha by indicatorGraceMs=" & $hudLiveGraceMs() & "ms. Set that " &
             "setting to 0 and this count must fall to zero and the blinking " &
             "must return -- that is what makes this claim falsifiable."

  # 6c. THE DRAW GATE (bug 1), reported as a COUNT of transitions rather than a
  # claim. `drawArmWhy` is INCONCLUSIVE, never PASS, whenever the arm's state
  # was carried across a phase the host could not read or does not export.
  let lGate = "arm=" & (if drawArmed(): "ARMED" else: "clear") &
              " phase=" & hostPhaseName(gArmLastPhase) &
              " arms=" & $gArmArms & " disarms=" & $gArmDisarms &
              " heldOnUnknown=" & $gArmUnknownHeld &
              " heldOnNoExport=" & $gArmNoExportHeld & "  " & drawArmWhy()
  # 7. the ART. The failure this whole feature exists to make impossible is a
  # silent fall back to a bare grid, so this line NEVER just reports a count:
  # it names the map, the layer and WHY that layer, or it names the reason
  # there is no art. Three outcomes, and "I could not look" is not a pass.
  var lArt = ""
  if not diagInRaid:
    lArt = "not in a raid, HUD idle -- " & diagRaidWhy
  elif not artLoaded():
    lArt = "FAIL  " & (if gArtWhy.len > 0: gArtWhy
                       else: "the tile manifest has not been read yet")
  elif not artValid():
    lArt = "INCONCLUSIVE  the manifest loaded (" &
           $artTiles() & " tiles bound) but no calibrated map matches this " &
           "raid, so the pane draws the LABELLED GRID and no art. " &
           artRefusalText()
  elif artDrawn() > 0:
    let byKey = resolveMapId(diagLocKey)
    lArt = "PASS  map=" & artMapId() &
           " layer level=" & $artLayerLevel() & " (" & artLayerWhy() & ")" &
           "  tiles " & $artDrawn() & " drawn / " & $artResident() &
           " resident / " & $artTiles() & " bound" &
           "  " & $artTilePx() & "px BC1" &
           (if byKey.len > 0:
              "  [by raid key '" & diagLocKey & "' -> " & byKey & "]"
            elif artCandidates() > 1:
              "  [GUESS: raid key '" & diagLocKey & "' has no calibration; " &
              $artCandidates() & " maps' bounds contain this position, smallest " &
              "taken]"
            else: "")
  else:
    let failId = resolveMapId(diagLocKey)
    let failIdText = (if failId.len > 0: failId else: "NO CALIBRATION")
    lArt = "FAIL  map=" & artMapId() &
           " (raid key '" & diagLocKey & "' -> " & failIdText &
           ") bound with " & $artTiles() &
           " tiles (" & $artResident() & " resident) but NOTHING was drawn: " &
           artRefusalText() &
           (if gArtWhy.len > 0: "  [" & gArtWhy & "]" else: "") &
           "  loads=" & $gArtLoaded & " readFails=" & $gArtReadFails

  # perf. The draw's own cost, in microseconds, measured on the render thread
  # (bug 4). Reported only once the callback has drawn at least one frame; before
  # that it is genuinely unmeasured, not "fast".
  var lPerf = ""
  if not gHudOn:
    lPerf = "INCONCLUSIVE  no HUD registered, so nothing has been timed"
  elif hudDrawn() <= 0'i64:
    lPerf = "INCONCLUSIVE  the callback has not drawn yet, so its cost is unmeasured"
  else:
    # PER PATH, not one anonymous peak. A total of 494us said only "something
    # spiked"; it could have been the tile submit, the small pane, the
    # full-screen overlay, the indicator loop or the host projector, and there
    # was no way to tell them apart without a rebuild. Each path now carries its
    # own worst case, so the next spike names itself.
    lPerf = "last=" & $hudDrawUsLast() & "us avg=" & $hudDrawUsAvg() &
            "us peak=" & $hudDrawUsPeak() & "us  tiles/frame=" & $hudTilesLast() &
            "  peak-by-path: art=" & $hudArtUsPeak() &
            "us minimap=" & $hudPaneUsPeak() &
            "us fullscreen=" & $hudFsUsPeak() &
            "us indicators=" & $hudIndUsPeak() &
            "us projector=" & $hudProjUsPeak() & "us" &
            "  projector calls=" & $hudProjCalls() & " (peak " &
            $hudProjCallsPeak() & "/frame, cap 24, deferred " &
            $hudProjDeferred() & ")" &
            " (budget " & $gOpts.budgetUs & "us; the region throttles this " &
            "participant after 8 consecutive overruns)" &
            (if hudDrawUsPeak() > int64(gOpts.budgetUs):
               "  OVER BUDGET at peak -- read the per-path numbers above; the " &
               "one whose peak is closest to the total is the spike"
             else: "")

  # THE TOGGLE LINE (Â§9b). The one check that would have caught the bug this
  # block exists for: an edit that STORES and never reaches the draw path.
  #
  # It compares two INDEPENDENT reads -- what config.json says right now, and
  # what the C mirror the draw callback dereferences every frame is actually
  # holding -- and it is deliberately NOT a re-read of our own write. A
  # self-comparison ("I pushed off, and off is what I pushed") cannot fail; this
  # can, and the input that makes it fail is exactly the reported bug: turn the
  # map off and see `config=off` next to `mirror=ON`.
  #
  # Three outcomes, never two. INCONCLUSIVE when no HUD is registered, because
  # there is then no mirror to disagree with and "I could not look" is not a
  # pass.
  # THE LATE-ARM CASE, and why it is its own outcome. The reported bug was
  # `enabled=false` at boot -> onLoad returned before armFeed -> flipping the
  # setting on in a raid stored the value and armed nothing. The old code
  # reported that as INCONCLUSIVE ("no HUD is registered"), which reads like a
  # missing instrument rather than the defect it is. It is now a FAIL with a
  # falsifiable statement: config says ON, and the collector is provably not
  # running. Three states, distinguishable, and a wrong one is observable:
  #   (a) config ON  + armed        -> the mirror comparison below
  #   (b) config ON  + NOT armed    -> FAIL, this bug
  #   (c) config OFF + not armed    -> PASS only if the mirror also reads off
  var lToggle = ""
  let cfgEnabledTop = asBool(setting("enabled"), false)
  if cfgEnabledTop and not gFeedRunning:
    lToggle = "FAIL  enabled=true in config.json but the live feed was NEVER " &
              "ARMED (gFeedRunning=false): no collector, no publish timer, so " &
              "nothing reads game memory and nothing can be drawn. This is the " &
              "late-arm defect -- the setting was stored and no arming ran. " &
              "Expect a 'maps: LATE ARM' line in this log if the apply hook fired."
  elif cfgEnabledTop and not gHudOn:
    lToggle = "FAIL  enabled=true and the collector IS running, but no draw " &
              "participant is registered (gHudOn=false), so the map page has a " &
              "feed and the in-game overlay submits no geometry."
  elif not gHudOn:
    if hudLiveEnabled():
      lToggle = "FAIL  enabled=false in config.json and no draw participant is " &
                "registered, yet the live mirror still reads enabled=ON -- the " &
                "mirror and the config disagree with nothing to reconcile them."
    else:
      lToggle = "PASS  enabled=false in config.json, no draw participant is " &
                "registered, and the live mirror reads enabled=OFF -- correctly " &
                "drawing nothing. Toggling `enabled` on will LATE ARM."
  else:
    let cfgEnabled = cfgEnabledTop
    var cfgOpts = HudOpts()
    readOpts(cfgOpts)
    let cfgMode    = cfgOpts.mode
    let cfgInd     = cfgOpts.indicators
    # The mirror's per-surface flags are config ANDed with `live`, so the only
    # legal disagreement is mirror=off while config=on (the feed is not
    # running). mirror=ON while config=off is ALWAYS a defect: it means an edit
    # was persisted and never applied, and the player is looking at art they
    # switched off.
    var leaked: seq[string] = @[]
    if (not cfgEnabled) and hudLiveEnabled(): leaked.add "enabled"
    if cfgMode == ModeOff and hudLiveMode() != ModeOff: leaked.add "spatialMode"
    if (not cfgInd)     and hudLiveIndicators(): leaked.add "hudIndicators"
    var mirrorTxt = "config(enabled=" & $cfgEnabled & " mode=" &
                    modeName(cfgMode) & " ind=" & $cfgInd & ")" &
                    " vs mirror(enabled=" & $hudLiveEnabled() & " mode=" &
                    modeName(hudLiveMode()) & " ind=" &
                    $hudLiveIndicators() & ")"
    if leaked.len > 0:
      var names = ""
      for k in leaked:
        if names.len > 0: names = names & ", "
        names = names & k
      lToggle = "FAIL  " & names & " is OFF in config.json and still ON in the " &
                "live draw mirror -- the edit was STORED and never APPLIED, so " &
                "the overlay is still being painted. " & mirrorTxt
    elif not hudLiveEnabled():
      lToggle = "PASS  the master switch is OFF and the draw callback is " &
                "submitting nothing (" & $hudGated() & " gated dispatch(es), " &
                "0 tiles). " & mirrorTxt
    else:
      lToggle = "PASS  no surface is off in config while still on in the live " &
                "mirror. " & mirrorTxt

  # The raw arming state, printed as three independent bits rather than as a
  # single "is it working" verdict, because collapsing them is what let the
  # late-arm bug hide: gEnabled could be true while gFeedRunning was false.
  let lArm = "gEnabled=" & $gEnabled & " gFeedRunning=" & $gFeedRunning &
             " gHudOn=" & $gHudOn & " armedAtBoot=" & $gArmedAtBoot &
             " lateArms=" & $gLateArms
  # The reconcile is the cross-process half of the apply path, so its state has
  # to be visible next to the toggle verdict it exists to clear.
  let lRecon = "timer=" & (if gReconcileOn: "registered" else: "NOT REGISTERED") &
               (if gReconcileOff: " DISABLED after repeated no-effect applies"
                else: "") &
               " reconciles=" & $gReconciles &
               " consecutiveNoEffect=" & $gReconcileFails

  # ---- THE UNIFIED WIDGET, as the mirror actually holds it ---------------
  #
  # Printed from the LIVE MIRROR, never from gOpts, so "what I meant to push"
  # and "what the render thread is reading" cannot be confused for each other.
  let lWidget = "mode=" & modeName(hudLiveMode()) &
                " rect=" & $hudLivePaneX() & "," & $hudLivePaneY() &
                " size=" & $hudLivePaneSize() &
                " span=" & $hudLivePaneSpan() & "m radius=" & $hudLiveRadius() &
                "m zoom=" & $hudLiveZoom() & " opacity=" & $hudLiveOpacity() &
                " art=" & $hudLiveDrawArt() & " contactPx=" &
                $hudLiveContactPx() & " grid=" & $hudLiveGrid() &
                " colours(bot/player)=" & $hudLiveColBot() & "/" &
                $hudLiveColPlayer()

  # ---- PLACEMENT, as RESOLVED, next to what was configured ----------------
  #
  # Both numbers, always. `cfg` is the inset the player typed; `drawnAt` is the
  # origin the anchor resolved to on the last drawn frame, written by the draw
  # path itself. In manual mode they are equal BY CONSTRUCTION -- and that is
  # stated, so their equality there is not read as evidence the anchor works.
  # In a corner mode they differ, and that difference is the evidence.
  # THREE OUTCOMES, never two (CLAUDE.md 9b). The old form printed the two
  # coordinate pairs and a caveat and left the reader to judge -- so a corner
  # anchor that had never drawn a frame reported `drawnAt=0.0,0.0`, which reads
  # exactly like "the anchor put the widget in the top-left corner" and is in
  # fact "nothing has been drawn". That is the INCONCLUSIVE case, and it now
  # says so by name instead of being reported as a position.
  #
  # The falsifiable NEGATIVE for a corner anchor is concrete: drawnAt MUST NOT
  # equal cfg, and the resolved origin must sit in the half of the screen the
  # chosen corner names. Both can fail, which is what makes this a check.
  let anch = hudLiveAnchor()
  let cx = hudLivePaneX()
  let cy = hudLivePaneY()
  let dx = hudWidgetX()
  let dy = hudWidgetY()
  # int32 from the region, widened once here: mixing it with the float origins
  # below is what the quadrant test compares, and one conversion in one place
  # beats four at the use sites.
  let sw: float = float(hudScreenW())
  let sh: float = float(hudScreenH())
  let wantRight: bool  = (anch == AnchorTR) or (anch == AnchorBR)
  let wantBottom: bool = (anch == AnchorBL) or (anch == AnchorBR)
  let inRightHalf: bool  = dx > (sw * 0.5)
  let inBottomHalf: bool = dy > (sh * 0.5)
  let placeVerdict =
    if anch == AnchorManual:
      "INCONCLUSIVE  manual placement: drawnAt EQUALS cfg by construction, so " &
      "this line proves nothing about the anchor until a corner is chosen"
    elif hudPaneCalls() == 0'i64:
      "INCONCLUSIVE  the anchor is set to " & anchorName(anch) &
      " but the pane renderer has NEVER run (0 draws), so drawnAt is the " &
      "uninitialised 0,0 and NOT a resolved position. Nothing is proven " &
      "until a frame is drawn in a raid"
    elif near(dx, cx) and near(dy, cy):
      "FAIL  anchor=" & anchorName(anch) & " but the drawn origin EQUALS the " &
      "configured inset, which is the manual behaviour -- the corner was not " &
      "resolved"
    elif inRightHalf != wantRight or inBottomHalf != wantBottom:
      "FAIL  anchor=" & anchorName(anch) & " resolved to " & $dx & "," & $dy &
      " on a " & $sw & "x" & $sh & " buffer, which is not in that corner's " &
      "quadrant"
    else:
      "PASS  anchor=" & anchorName(anch) & " resolved the origin to " &
      $dx & "," & $dy & " from the inset " & $cx & "," & $cy & " on a " &
      $sw & "x" & $sh & " buffer -- in the named quadrant and NOT equal to " &
      "cfg, over " & $hudPaneCalls() & " pane draw(s)"
  let lPlace = placeVerdict &
               ". anchor=" & anchorName(anch) &
               " cfg=" & $cx & "," & $cy &
               " drawnAt=" & $dx & "," & $dy &
               "  border=" & (if hudLiveBorder(): "on@" & $hudLiveBorderPx() &
                                                  "px" else: "off") &
               " backdropOpacity=" & $hudLiveBackdropOpacity()

  # ---- ONE RENDERER, asserted as a NEGATIVE -------------------------------
  #
  # `paneCallsOver` counts dispatches on which mhud_draw_pane_full ran MORE THAN
  # ONCE. It is incremented inside the renderer, so it counts draws that
  # happened, not draws we believe happened. Non-zero = a second draw path
  # exists and the minimap and the radar have forked again.
  let lUnified =
    if hudPaneCalls() == 0'i64:
      "INCONCLUSIVE  the pane renderer has not run yet (0 calls), so nothing " &
      "about the unified path has been observed. This is not a pass."
    elif hudPaneCallsOver() > 0'i64:
      "FAIL  " & $hudPaneCallsOver() & " dispatch(es) rendered MORE THAN ONE " &
      "pane -- a second draw path is submitting behind the first (calls=" &
      $hudPaneCalls() & ")"
    else:
      "PASS  " & $hudPaneCalls() & " pane render(s), and no dispatch ever " &
      "rendered more than one: the minimap, the radar and the full-screen " &
      "overlay are the same code path"

  # ---- THE RENDERER CHOICE, and "NOTHING DREW" AS A FAIL ------------------
  #
  # Two independent assertions, kept apart because they fail independently:
  #
  #   * `paneCallsOver` (the unifiedPane line above) catches the DOUBLED draw.
  #   * `selBlank` catches the opposite and much quieter failure -- a surface
  #     was SELECTED and the renderer submitted zero primitives on every frame
  #     it was asked to draw. That is the reported bug, and the old diag had no
  #     counter that could express it: an all-zero renderer read as a PASS
  #     everywhere, because every check compared our own config to itself.
  #
  # PASS requires selDrew > 0 -- the winning renderer put geometry on screen at
  # least once. selFrames == 0 is INCONCLUSIVE ("no surface was ever selected,
  # so nothing was observed"), never PASS.
  let selF = hudSelFrames()
  let selD = hudSelDrew()
  let selB = hudSelBlank()
  # THE CONFIG-LEVEL ASSERTION, ahead of every counter branch, because the
  # counters could not express this failure at all. MEASURED: this verdict read
  # "PASS ... 42 of 42 dispatch(es) (0 blank) ... renderer=LEGACY" while the
  # player's screen was empty, from mapsRenderer="legacy" + hudRadar=false +
  # hudMap=false. Every counter was asserting "the renderer ran"; none was
  # asserting "a surface the player can see was switched on". Those are
  # different claims and only the first was ever checked.
  #
  # `ownerBlank` is the falsifiable negative that was missing. With the
  # fall-through in rendererOwner in place it is UNREACHABLE unless the player
  # explicitly asked for off -- so if the FAIL arm below ever fires, the
  # fall-through is broken, and that is precisely a check that CAN fail.
  let ownerEff = rendererOwner()
  let ownerBlank =
    if ownerEff == RendUnified: not unifiedSurfacesOn()
    else: not legacySurfacesOn()
  let lRend =
    if ownerBlank and not explicitOff():
      "FAIL  every surface belonging to the renderer that owns the widget is " &
      "DISABLED, so nothing visible can be drawn no matter how many dispatches " &
      "reach the draw path (" & $selD & " of " & $selF & " submitted geometry " &
      "-- a count of dispatches is NOT a count of visible pixels). " &
      (if not (legacySurfacesOn() or unifiedSurfacesOn()):
         "BOTH key sets are empty, so there was nothing to fall through to. " &
         "The usual cause is a `spatialMode` spelling this build does not " &
         "recognise (which resolves to off) while both Legacy toggles are also " &
         "off. Fix either key set, or say spatialMode=\"off\" if you meant off."
       else:
         "The other key set DOES have a surface, so the empty-provider " &
         "fall-through should have made this state unreachable -- this is a " &
         "REGRESSION in rendererOwner, not a config the player can reach.") &
      " " & rendererSurfaces() & ". " & rendererDecision()
    elif ownerBlank:
      "INCONCLUSIVE  the widget is OFF because spatialMode=\"off\" was asked " &
      "for EXPLICITLY, and that is honoured under both renderers. Nothing drew " &
      "and nothing was asked to -- this is not a pass and not a fault. " &
      rendererSurfaces()
    elif hudPaneCallsOver() > 0'i64 or hudPaneCallsUnder() > 0'i64:
      "FAIL  the pane ledger disagrees with the mode: " &
      $hudPaneCallsOver() & " dispatch(es) drew MORE panes than " &
      modeName(gOpts.mode) & " entitles (a second draw path exists) and " &
      $hudPaneCallsUnder() & " drew FEWER (a selected surface was dropped). " &
      "The entitlement (" & $hudPaneExpect() & ") is resolved from the mode " &
      "BEFORE any pane is drawn, so this compares the draw against an " &
      "expectation it could not have been written to match. " &
      rendererDecision()
    elif selD + selB != selF:
      "FAIL  the draw-site counters do not add up (selDrew " & $selD &
      " + selBlank " & $selB & " != selFrames " & $selF & "), so no verdict " &
      "about the renderer can be trusted. " & rendererDecision()
    elif not gHudOn:
      "INCONCLUSIVE  no draw participant is registered, so no dispatch has " &
      "reached the renderer and nothing has been observed. " & rendererDecision()
    elif selF == 0'i64 and hudRaidFrames() >= int64(gDrawVerdictFrames):
      # THE BOUND. The arm below this one is honest while the raid is still
      # starting and dishonest forever after: "no dispatch has reached the draw
      # section yet" is a sentence that can be true on frame 3 and is a defect
      # on frame 3000. `hudRaidFrames` counts dispatches that got PAST the
      # in-raid lifecycle gate -- so this can only fire when drawing was
      # genuinely possible, and it names the mode that was asked for.
      "FAIL  spatialMode=" & modeName(gOpts.mode) & " has been selected for " &
      $hudRaidFrames() & " in-raid dispatch(es) (budget " &
      $gDrawVerdictFrames & ", `drawVerdictFrames`) and NOT ONE of them " &
      "reached the draw section with a surface switched on. The mode is set " &
      "and the draw path is never being entered -- that is a defect, not a " &
      "slow start. " & rendererSurfaces() & ". " & rendererDecision()
    elif selF == 0'i64:
      "INCONCLUSIVE  a renderer is selected in config but ZERO dispatches " &
      "reached the draw section with any surface switched on (the widget " &
      "mode is " & modeName(gOpts.mode) & " and the overlay has not been " &
      "opened) -- after " & $hudRaidFrames() & " in-raid dispatch(es) of a " &
      $gDrawVerdictFrames & "-frame budget, past which this becomes a FAIL. " &
      "Nothing drew and nothing was asked to -- this is NOT a pass. " &
      rendererSurfaces() & ". " & rendererDecision()
    elif selD == 0'i64:
      "FAIL  a surface was selected on all " & $selF & " dispatch(es) and " &
      "the renderer submitted ZERO primitives on every one of them -- the " &
      "map/radar is switched on and NOTHING IS BEING DRAWN. This is the " &
      "reported defect, not a quiet widget. " & rendererSurfaces() & ". " &
      rendererDecision()
    else:
      "PASS  the selected renderer submitted geometry on " & $selD & " of " &
      $selF & " dispatch(es) (" & $selB & " blank), every dispatch rendered " &
      "EXACTLY the number of panes its mode entitles it to (" &
      $hudPaneExpect() & " for " & modeName(gOpts.mode) & "; " &
      $hudPaneCallsOver() & " over, " & $hudPaneCallsUnder() & " under), " &
      "AND the owning renderer has at least one surface switched on. " &
      (if gOpts.mode == ModeBoth:
         "BOTH: last frame the minimap pane submitted " & $hudMapPrims() &
         " primitive(s) at (" & $int(hudLivePaneX()) & "," &
         $int(hudLivePaneY()) & ") and the radar pane " & $hudRadarPrims() &
         " at (" & $int(hudRadarWx()) & "," & $int(hudRadarWy()) &
         ") -- counted apart, because a mode that draws one surface and " &
         "silently drops the other is exactly what a combined count hides. "
       else: "") &
      rendererSurfaces() & ". " & rendererDecision()

  # ---- THE FULL-SCREEN OVERLAY -------------------------------------------
  #
  # THREE OUTCOMES, and the PASS is a falsifiable NEGATIVE: the overlay was open
  # on N frames AND the small widget submitted ZERO primitives on all N of them.
  # `fsSuppressed` is counted at the draw site from the small widget's own
  # return value, so a small-widget submission added later outside the guard
  # would make the two numbers differ and this would read FAIL. A single
  # "overlay drew" counter could not be falsified and would not be a check.
  # THE ACTIVATION MODE, stated on its own line and BEFORE the verdict, because
  # every number the verdict below quotes means something different under HOLD:
  # `toggles` counts open/close EDGES rather than presses, and a "the key was
  # pressed N times and the overlay never opened" complaint about a hold key
  # would be reading a press-mode instrument.
  var lAct = "activation=" & activationNameOf(hudLiveFsMode())
  if hudLiveFsMode() == ActHold:
    lAct = lAct & " (level read) opens=" & $hudFsHoldOpens() &
           " closes=" & $hudFsHoldCloses() &
           " heldFrames=" & $hudFsHeldFrames() & "  " & hudHeldBindText()
    if hudFsHoldOpens() > hudFsHoldCloses() + 1'i64:
      lAct = lAct & "  FAIL  the overlay opened " & $hudFsHoldOpens() &
             " time(s) and closed " & $hudFsHoldCloses() &
             " -- a level read must close on the poll after release, so this " &
             "is a stuck overlay, not a player still holding the key."
  else:
    lAct = lAct & " (edge read, a toggle)"
  if hudLiveFsMode() != gOpts.fsMode:
    lAct = lAct & "  FAIL  config asks for " & activationNameOf(gOpts.fsMode) &
           " and the live mirror holds " & activationNameOf(hudLiveFsMode()) &
           " -- the setting is stored and NOT in force."

  # THE LEVEL OF DETAIL and THE ENEMY POLICY, both stated as what is IN FORCE
  # rather than what is on disk.
  var lDetail = "detail=" & detailNameOf(gOpts.detail) &
                " -> art=" & $gOpts.drawArt & " grid=" & $(gOpts.mapGrid > 0) &
                " pip=" & $gOpts.northPip
  if gOpts.detail == DetailCustom:
    lDetail = lDetail & " (custom: your three switches decide; this row " &
              "overrode nothing)"
  else:
    lDetail = lDetail & " (a PRESET: it overrides the three switches, and the " &
              "override is logged by name when it changes one)"
  var lEnemy = "enemyVisibility -> " & enemyPolicyNameOf(gOpts.enemyPolicy) &
               " IN FORCE"
  if not enemyPolicyAvailable(enemyPolicyOfName(
       asText(setting("enemyVisibility"), "always"))):
    lEnemy = "INCONCLUSIVE  " & EnemyShootOnlyWhy

  var lFs = ""
  if not gFsHotkeysOn:
    lFs = "INCONCLUSIVE  the `hotkeys` setting is OFF (the shipped default), " &
          "so no key is polled and the full-screen map cannot be opened. " &
          "Nothing was called -- not GetModuleHandle, not Input::GetKeyDown."
  elif gFsKeyKc < 0:
    lFs = "INCONCLUSIVE  `hotkeys` is ON but `fullscreenKey` = \"" & gFsKeyName &
          "\" is not a UnityEngine.KeyCode name, so it resolved to UNBOUND " &
          "and nothing is polled. This is a misspelling, not an idle key."
  elif not gHudOn:
    lFs = "INCONCLUSIVE  key " & gFsKeyName & " (kc=" & $gFsKeyKc &
          ") is bound but no draw participant is registered, so opening the " &
          "overlay would draw nothing. bind: " & hudKeyBindText()
  elif hudFsRejected() > 0'i64:
    # THE CONTROL-KEY CHECK -- the one that could have caught the any-key bug.
    # On every tick where the bound key reads DOWN we also ask the same
    # function about Joystick8Button19, which the player cannot be holding. If
    # that says down too, the read is not honouring its keycode argument and
    # the toggle is REFUSED rather than opening a panel over the raid.
    # `toggles` alone can never fail this way, which is exactly why the bug
    # shipped behind a green line.
    lFs = "FAIL  the input read is INDISCRIMINATE: on " & $hudFsRejected() &
          " of " & $hudFsKeyDowns() & " tick(s) where " & gFsKeyName &
          " read down, a key the player cannot be holding " &
          "(Joystick8Button19) read down in the SAME poll. Those toggles were " &
          "REFUSED, so the overlay did not open on them. bind: " &
          hudKeyBindText()
  elif hudFsToggles() == 0'i64:
    lFs = "INCONCLUSIVE  key " & gFsKeyName & " (kc=" & $gFsKeyKc &
          ") is armed and polled and has NEVER been pressed -- 0 toggles, so " &
          "the overlay has never opened and nothing about it is proven. " &
          "bind: " & hudKeyBindText()
  elif hudFsFrames() == 0'i64:
    lFs = "FAIL  the key was pressed " & $hudFsToggles() & " time(s) and the " &
          "overlay drew on 0 frame(s): the toggle reached the mirror and the " &
          "draw never honoured it. bind: " & hudKeyBindText()
  elif hudFsSuppressed() != hudFsFrames():
    lFs = "FAIL  the overlay was open on " & $hudFsFrames() & " frame(s) but " &
          "the small widget submitted primitives on " &
          $(hudFsFrames() - hudFsSuppressed()) & " of them -- the full-screen " &
          "map is drawing OVER a live minimap instead of replacing it"
  elif hudFsRectBad() > 0'i64:
    # THE RECT CHECK. The renderer recorded the rect it was HANDED; the draw
    # site compared that against the screen square derived independently from
    # the measured back buffer. A mismatch means the overlay is not full-screen,
    # which no primitive count would have caught.
    lFs = "FAIL  the overlay drew on " & $hudFsFrames() & " frame(s) but its " &
          "pane rect did not match the screen square on " & $hudFsRectBad() &
          " of them -- the full-screen map is not full-screen (ok=" &
          $hudFsRectOk() & ")"
  else:
    lFs = "PASS  open on " & $hudFsFrames() & " frame(s), rect matched the " &
          "screen square on all " & $hudFsRectOk() & " of them, and the small " &
          "widget submitted ZERO primitives on all " & $hudFsFrames() &
          " of them (toggles=" & $hudFsToggles() & " from " &
          $hudFsKeyDowns() & " key-down tick(s), 0 refused by the " &
          "control-key check, key=" & gFsKeyName &
          ", currently " & (if hudFsOpen(): "OPEN" else: "closed") &
          ", last overlay submit=" & $hudFsLastPrims() & " primitive(s)). " &
          "bind: " & hudKeyBindText()

  result = "maps diag:\n" &
           "  arm          : " & lArm & "\n" &
           "  widget       : " & lWidget & "\n" &
           "  placement    : " & lPlace & "\n" &
           "  unifiedPane  : " & lUnified & "\n" &
           "  renderer     : " & lRend    & "\n" &
           "  detail       : " & lDetail & "\n" &
           "  enemyPolicy  : " & lEnemy & "\n" &
           "  fsActivation : " & lAct & "\n" &
           "  fullscreen   : " & lFs & "\n" &
           "  reconcile    : " & lRecon & "\n" &
           "  region       : " & lRegion & "\n" &
           "  world        : " & lWorld  & "\n" &
           "  phase        : " & hostPhaseName(lPhaseV) & "  " & lPhase & "\n" &
           "  raid         : " & lRaid   & "\n" &
           "  positions    : " & lPos    & "\n" &
           "  toggle       : " & lToggle & "\n" &
           "  draw         : " & lDraw   & "\n" &
           "  drawCost     : " & lPerf   & "\n" &
           "  screen       : " & lScreen & "\n" &
           "  projector    : " & lProj   & "\n" &
           "  heading      : " & lHdg    & "\n" &
           "  indLifetime  : " & lLife   & "\n" &
           "  indFlicker   : " & lFlick  & "\n" &
           "  drawGate     : " & lGate   & "\n" &
           "  art          : " & lArt    & "\n" &
           # TWO independent class stages, because they can fail independently
           # and folding them would hide one behind the other. `classify` is
           # about the READ (did the Profile walk produce a real distribution);
           # `classFilter` is about the DRAW (did an OFF class still reach the
           # screen). A perfect classifier feeding a broken filter, and a dead
           # classifier feeding a correct filter, are both possible and both
           # visible here.
           "  classify     : " & clsVerdict() & "\n" &
           "  classHist    : " & clsHistogramText(clsEver()) &
             "  (cumulative, this session)\n" &
           "  classFilter  : " & hudClassVerdict() & "\n" &
           "  feed         : ticks=" & $gTicks & " published=" & $gPublished &
             " faults=" & $feedFaults() & " defect=" & feedDefect()

proc onDiagTick(payload: string): string =
  ## Always announces. The FIRST tick prints unconditionally -- so a session in
  ## which everything is broken from the start still gets a full report -- and
  ## afterwards it prints on any CHANGE, plus a periodic heartbeat so a
  ## long-running stuck state cannot scroll away and be forgotten.
  ##
  ## The re-announcement schedule for a STANDING not-PASS is `diagStep`'s, not
  ## this proc's: every 60 s in a raid, once per host phase outside one. See
  ## diagfilter.nim for why -- at the menu the honest verdict for most of the
  ## block is INCONCLUSIVE, and repeating "I could not look" every minute
  ## forever is noise, while in a raid a standing FAIL must keep naming itself.
  inc gDiagTicks
  let text = mapsDiagText()
  let sig = diagSignature(text)
  let bad = diagNotPass(text)
  lockMod()
  let stepLive = activeRaid(gSnap)
  unlockMod()
  let stepPhase = hostPhase()
  if gDiagVerbose:
    # THE FIREHOSE, opt-in. Byte-for-byte the old behaviour.
    info text
  else:
    let emit = diagStep(gDiagRep, sig, bad.len > 0, stepLive, stepPhase)
    case emit
    of DeBlock:
      # A VERDICT MOVED -- or this is the first tick, which always prints in
      # full, so a session broken from the very start still gets a whole report.
      # Print the block, because context matters exactly when something has just
      # changed, and then name the not-PASS lines on their OWN line at warn so
      # they are greppable and cannot be lost inside eighteen lines of prose.
      info text
      if bad.len > 0:
        warn ModName & ": diag NOT-PASS: " & bad
    of DeStill:
      # A FAIL or INCONCLUSIVE is NEVER collapsed into an all-clear heartbeat
      # and is never suppressed outright. In a raid it is re-announced every 30
      # cycles (60 s), naming itself, for as long as it lasts. Outside a raid it
      # is announced once per phase: the block re-prints in full the moment any
      # verdict moves, and the phase name is PART of the signature, so a real
      # change still surfaces on the cycle it happens.
      var stillWhen = ", no raid -- next report on a phase change"
      if stepLive:
        stillWhen = ", raid live -- next report in 60s"
      warn ModName & ": diag STILL NOT-PASS after " & $gDiagRep.quiet &
           " unchanged cycle(s) (" & $(gDiagRep.quiet * 2'i64) & "s, phase " &
           hostPhaseName(stepPhase) & stillWhen & "): " & bad &
           ". Turn on the `diagVerbose` setting for the full block every tick."
    of DeHeartbeat:
      # Everything reads PASS and has not moved. One line every 5 minutes, and
      # it is a HEARTBEAT, not a verdict: it says the instrument is still
      # running and how long the verdicts have stood. Pure silence here would
      # be indistinguishable from a dead timer, which is the same "I could not
      # look reads as a pass" failure this block exists to prevent.
      info ModName & ": diag all-PASS, unchanged for " & $gDiagRep.quiet &
           " cycle(s) (" & $(gDiagRep.quiet * 2'i64) & "s). The full block is " &
           "re-printed the moment any verdict changes."
    of DeNone:
      discard
  # THE PHASE PROFILE, on the SAME 2s timer, and unconditional when the flag is
  # set: it is cumulative, so an unchanged line is still new information (the
  # means moved). It reports INCONCLUSIVE below its tick threshold rather than a
  # number, so "I could not look yet" cannot read as a pass.
  if mpEnabled() != 0'i32:
    inc gProfCycles
    let pt = mpTicks()
    if pt == gProfLastTicks: inc gProfIdle else: gProfIdle = 0'i64
    gProfLastTicks = pt
    if gProfVerbose:
      # THE FIREHOSE, opt-in. Byte-for-byte the old behaviour.
      info ModName & ": " & mapsProfLine()
    elif gProfIdle > 0'i64:
      # THE METER DID NOT ADVANCE. Nothing was profiled since the last cycle,
      # so re-printing the decomposition would be kilobytes restating one fact.
      # That one fact is still stated, on its own line, every 60s -- and it is
      # stated as NOT-MEASURED, never as an all-clear.
      if (gProfIdle mod 30'i64) == 1'i64:
        info ModName & ": prof: profiler ON but the meter has NOT ADVANCED " &
             "for " & $gProfIdle & " cycle(s) (" & $(gProfIdle * 2'i64) &
             "s) -- " & $pt & " bracketed tick(s) total. Nothing ran to " &
             "profile; this is NOT 'free' and NOT measured. The full block " &
             "prints again the moment the meter moves; " &
             "`profileVerbose` restores it every tick."
    elif gProfCycles == 1'i64 or (gProfCycles mod 150'i64) == 0'i64:
      # THE FULL DECOMPOSITION. First cycle always, then every 5 minutes while
      # the meter is actually advancing. The line is CUMULATIVE, so a 5-minute
      # sample is strictly better evidence than the same means re-derived 150
      # times, and `mapsProfLine` still reports INCONCLUSIVE below its own tick
      # threshold rather than a number.
      info ModName & ": " & mapsProfLine()
    # THE TWO CACHES, on the same timer as the profile they exist to move.
    # `ecVerdict` is the falsifiable negative -- "no per-entity constant is
    # recomputed on a tick where the entity list did not change" -- and it can
    # say FAIL and INCONCLUSIVE, not only PASS. Emitted ON CHANGE, by the same
    # signature the diag block uses, with a not-PASS re-announcement no
    # signature can silence.
    let cText = rdCacheText() & "\n" & ecText() & "\n" & ecVerdict()
    let cSig = diagSignature(cText)
    let cBad = diagNotPass(cText)
    if gProfVerbose or gCacheLast.len == 0 or cSig != gCacheLast:
      gCacheLast = cSig
      gCacheQuiet = 0'i64
      info ModName & ": " & rdCacheText()
      info ModName & ": " & ecText()
      info ModName & ": " & ecVerdict()
    else:
      inc gCacheQuiet
      if cBad.len > 0:
        if (gCacheQuiet mod 30'i64) == 0'i64:
          warn ModName & ": cache STILL NOT-PASS after " & $gCacheQuiet &
               " unchanged cycle(s) (" & $(gCacheQuiet * 2'i64) & "s): " &
               cBad & ". Turn on `profileVerbose` for the full lines."
      elif (gCacheQuiet mod 150'i64) == 0'i64:
        info ModName & ": cache all-PASS, unchanged for " & $gCacheQuiet &
             " cycle(s) (" & $(gCacheQuiet * 2'i64) & "s)."
  result = ""

proc armFeed(): bool =
  ## Register the position collector, the publish timer, and -- when any HUD
  ## surface is on -- the in-game draw participant. This is the ONE arming path,
  ## called from onLoad AND from the hot-apply hook when `enabled` flips
  ## false->true in a live raid (the map hot-starts without a relaunch). It is
  ## IDEMPOTENT: gFeedRunning guards the two timers and gHudOn guards the region
  ## participant, so a repeated toggle can never double-register a timer or add a
  ## second region participant. It does NOT read game memory itself and it does
  ## not decide whether anything DRAWS -- the in-raid lifecycle gate in hud.nim
  ## still owns that -- so calling it outside a raid arms the feed and waits.
  ## Returns true when the collector timers are running.
  if not gFeedRunning:
    # everyMain, NOT whenReady("EFT.GameWorld"). Fact #141: that gate tests
    # whether a TYPE RESOLVES, which is true from il2cpp_init onward whether or
    # not a world or a Unity thread exists -- a check that cannot fail, and it
    # has killed the client for three separate mods. The real liveness test is
    # `gwState()`, which asks the host's already-armed detour whether it has
    # actually cached a world, and reports "no host export" and "armed but
    # empty" as DIFFERENT answers.
    if everyMain(onMainTick) != Ok:
      warn ModName & ": could not register the main-thread collector; the live " &
           "feed will not run. The map still opens with terrain and no markers."
      return false
    if every(1000 div gHz, onPublishTick) != Ok:
      warn ModName & ": collector registered but the publish timer did not; " &
           "positions are being read and nothing is being written."
      return false
    gFeedRunning = true

  # The in-game draw. It rides the SHARED region (abi/aowlspt_region.h) as one
  # more participant on the existing PreloaderUI::Update rider chain -- it does
  # NOT add a second detour, and it does not borrow mods/admin's private HUD.
  # Registration and ARMING are reported separately on purpose: registration
  # always succeeds, and a registered participant on an unarmed region simply
  # never fires. Flattening those two into "the radar is on" would be a claim
  # that cannot be falsified.
  # Register when ANY surface is on -- map included. The map draw is gated on
  # `mapOn` inside the callback, so a map-only config must still register the
  # participant; the earlier `radar or indicators` gate silently denied the map
  # its own callback whenever the radar happened to be off. Guarded by gHudOn so
  # a hot-start re-toggle does not add a second participant.
  # Register when ANY surface can draw -- including the FULL-SCREEN overlay,
  # which is a surface even with the widget mode OFF. Without that clause a
  # player whose only spatial surface is the full-screen map would get no draw
  # participant at all and the key would open nothing, silently.
  # Reaching here means the registration DECISION is being taken -- which is the
  # fact the `region` diag line needs in order to tell "never attempted" apart
  # from "attempted and refused". Set before the surface gate, so a config with
  # every surface off is still recorded as tried.
  gHudTried = true
  if (gOpts.mode != ModeOff or gOpts.indicators or
      (gOpts.fsEnabled and gFsKeyKc >= 0)) and not gHudOn:
    hudInit(gOpts)
    var whyHud = ""
    if hudRegister(gOpts, whyHud):
      gHudOn = true
      gHudRefusal = ""
      if hudArmed():
        success ModName & ": in-game HUD registered with the shared region " &
                "and the region is ARMED -- mode=" & modeName(gOpts.mode) &
                " indicators=" & $gOpts.indicators &
                " fullscreenKey=" & (if gFsKeyKc >= 0: gFsKeyName else: "(unbound)")
      else:
        warn ModName & ": in-game HUD registered, but the shared region is " &
             "NOT armed, so the callback will never fire and nothing will be " &
             "drawn. Set the host flag `sharedRegion` in aowlspt-host.json. " &
             "This is not 'the radar is off' -- it is 'nothing is dispatching'."
    else:
      gHudRefusal = whyHud
      warn ModName & ": the shared region refused the in-game HUD: " & whyHud &
           ". The map page still works; the radar and the indicators do not."
  result = gFeedRunning

proc onMapsApply(key: string) =
  ## THE HOT-APPLY HOOK (bug 1). Before this proc existed maps registered NONE,
  ## so an F12 edit reached config.json and stopped there: the live HUD kept
  ## whatever it read at startup, and "turn the map off in settings" left the map
  ## on screen (fact #213 -- settings queued and never applied). The draw reads
  ## `mapOn`/`radarOn`/`indicatorsOn` from the C mirror every frame, so applying
  ## an edit is just re-reading config and pushing it back into that mirror.
  ##
  ## The verdict is reported honestly (settingApplied / -Restart / -Ignored) so
  ## the host log distinguishes "in force now" from "stored, relaunch needed"
  ## from "stored but nothing draws it".
  if side() != sideClient:
    settingIgnored("this is the server instance; the client instance owns the HUD")
    return
  let wasEnabled = gEnabled
  let nowEnabled = asBool(setting("enabled"), false)
  loadHudOpts()                       # refresh gOpts + gHeadingOn from config

  # THE LATE ARM (bug 3), and why it is NOT under `if key == "enabled"`.
  #
  # `gEnabled` used to be refreshed ONLY inside that branch, and `key` is
  # `field(payload,"key").asText("")` (aowl/src/aowlspt/settings.nim:698) -- it is
  # "" for a whole-page apply and for a RESET, and it is whatever the UI happens
  # to name otherwise. So a reset that restored `enabled=true`, or any apply that
  # did not carry exactly the string "enabled", fell through to the generic
  # verdict below with `gEnabled` still holding its stale boot-time `false`, and
  # answered settingIgnored("stored; nothing is drawn..."). That is the reported
  # bug: turn the map on in a raid, nothing happens. The transition is now
  # derived from the CONFIG VALUE, not from the key, so no key spelling can lose
  # it. `key` is used for the message only.
  gEnabled = nowEnabled               # unconditional; gates onMainTick/onPublishTick
  var armWanted = false
  var armOk = true
  if nowEnabled and ((not gFeedRunning) or (not gHudOn)):
    # Something is genuinely unarmed. armFeed is IDEMPOTENT -- gFeedRunning
    # guards the two timers and gHudOn guards the draw participant -- so calling
    # it on every apply could not double-register; we gate anyway so that
    # `gLateArms` counts real arming work and stays flat across repeated
    # toggling, which is the idempotence evidence the diag prints.
    armWanted = true
    armOk = armFeed()
    if armOk: inc gLateArms
    info ModName & ": LATE ARM " & (if armOk: "SUCCEEDED" else: "FAILED") &
         " (booted with enabled=" & $gArmedAtBoot &
         ") -> gFeedRunning=" & $gFeedRunning & " gHudOn=" & $gHudOn &
         " lateArms=" & $gLateArms

  # `live` is computed AFTER the arm, so a false->true transition pushes
  # live=true into the mirror on this same apply instead of one apply later.
  let live = gEnabled and gFeedRunning
  hudReconfigure(gOpts, live)         # next frame honours it; no position reset
  # A MAPS-OWNED TRACE, unconditional and BEFORE the verdict branches below
  # (bug 2). The earlier apply hook left no line of its own in the host log, so
  # "the toggle did nothing" and "the hook never fired" were indistinguishable.
  # This prints the exact values just pushed into the C mirror the draw callback
  # reads every frame -- `mapOn`/`radarOn`/`indicatorsOn` are each ANDed with
  # `live`, so an off edit shows the surface at 0 here and the NEXT draw frame
  # honours it (0 tiles / 0 blips). This is the finished-state assertion the fix
  # is judged on: not "apply returned ok" but "the mirror now reads off".
  # THE RENDERER DECISION, named on every apply. espProvider's rule: the winner
  # and the loser are both stated, with the reason the loser is still armed --
  # a renderer that disappears without a named reason is what produced "if i
  # disable the legacy maps i see no in game map/radar".
  info "maps: " & rendererDecision()
  info "maps: apply " & (if key.len > 0: key else: "(all)") &
       " -> config spatialMode=" & modeName(gOpts.mode) &
       " indicators=" & $gOpts.indicators & " enabled=" & $nowEnabled &
       " live=" & $live & " -> mirror pushed mode=" &
       modeName(hudLiveMode()) & " indicatorsOn=" &
       $(gOpts.indicators and live) & " fullscreenKey=" &
       (if gFsKeyKc >= 0: gFsKeyName else: "(unbound)")
  # The verdict is driven by the TRANSITION (or by an explicit `enabled` key),
  # never by the key alone -- see the late-arm comment above.
  if nowEnabled != wasEnabled or key == "enabled":
    if nowEnabled:
      # HOT-START. The arming already happened above, through the SAME armFeed()
      # path onLoad uses. gEnabled was set before it, so the freshly registered
      # onMainTick/onPublishTick do real work on their first fire. The in-raid
      # lifecycle gate in hud.nim still owns whether anything DRAWS, so this only
      # makes the map begin drawing on the next IN-RAID frame; outside a raid the
      # feed arms and waits.
      if gFeedRunning and armOk:
        settingApplied("feed " &
          (if armWanted: "LATE-ARMED in place" else: "already armed") &
          " without relaunch -- collector running" &
          (if gHudOn: "; in-game HUD registered"
           else: "; NO draw participant (every HUD surface is off in config)") &
          "; draws on the next in-raid frame (in-raid lifecycle gate applies). " &
          "lateArms=" & $gLateArms)
      else:
        settingIgnored("could not arm the live collector (gFeedRunning=" &
          $gFeedRunning & "); see the warning above -- the map page still opens " &
          "and will report that no feed is arriving")
    else:
      # true->false: gEnabled now gates the collector ticks to no-ops, and the
      # hudReconfigure above already pushed live=false into the mirror (mapOn=
      # radarOn=indicatorsOn=0), so the very next draw frame submits nothing. The
      # timers and the region participant stay registered but idle -- a later
      # re-enable hot-starts through armFeed's idempotent guards.
      settingApplied("feed OFF -- HUD blanked (0 tiles, 0 blips)")
    return
  if not (gEnabled and gFeedRunning and
          (gOpts.mode != ModeOff or gOpts.indicators or
           (gOpts.fsEnabled and gFsKeyKc >= 0))):
    settingIgnored("stored; nothing is drawn because the feed is off or every " &
      "spatial surface (widget mode / indicators / full-screen key) is off")
    return
  settingApplied("mode=" & modeName(gOpts.mode) &
                 " indicators=" & $gOpts.indicators & " heading=" & $gHeadingOn &
                 (if gHeadingOn: " (heading-up: art refuses, grid+blips rotate)"
                  else: " (north-up: baked art drawn)"))

# ---------------------------------------------------------------------------
# THE RECONCILE TICK -- the choke point, and why it is not a fourth transport
# patch
# ---------------------------------------------------------------------------
#
# Three transports have now each been patched to call `onMapsApply` and the OFF
# direction survived all three. It survived because THE WRITE AND THE DRAW ARE
# IN DIFFERENT PROCESSES.
#
#   * `sides = {sideServer, sideClient}`, so this mod loads twice.
#   * `registerRoutes`/`serve` only succeed in the BACKEND process, so the F12
#     panel's `POST /aowlspt/settings/aowl.maps` (overlay:
#     abi/aowlspt_overlay.h:3922 `if (isMod) .../aowlspt/settings/<guid>`) is
#     answered by the SERVER instance.
#   * that instance runs `onSpatialSettings` -> `applySettingFromBody` ->
#     `onMapsApply`, and `onMapsApply`'s FIRST line is
#     `if side() != sideClient: settingIgnored(...); return`.
#
# So the store happened in one process and the C draw mirror lives in the other,
# which never heard anything. No amount of hooking the server-side transports
# can fix that, and there is no in-process choke point that both sides pass
# through -- the event bus does not cross the process boundary and settingshub's
# client queue is only fed by `/aowlspt/settings/client/page/<guid>`, which
# nothing in the overlay ever requests.
#
# The one thing EVERY writer does converge on is `config.json` itself: the
# SDK's `applySetting`, `resetSetting`, `resetAllSettings`, the backfill, this
# mod's own route, the bus path, the uihub page and any transport not yet
# written all end in `hostConfigSet` merging a key into that file. So the
# CLIENT instance watches the file, on its own timer, and reconciles the live
# mirror to it. A future fourth transport cannot bypass this, because bypassing
# it would mean not persisting the edit at all.
#
# The check is the finished-state comparison (Â§9b), not a re-read of our own
# write: what config.json says NOW versus what the C mirror the draw callback
# dereferences every frame is actually holding. It is the same comparison the
# `toggle` diag line makes -- deliberately, so the instrument that detects the
# bug and the mechanism that fixes it cannot drift apart.
#
# Bounded, and it self-disables. If a reconcile runs and the SAME drift is
# still there on the next tick, the reconcile is not working; after
# `MaxReconcileFails` consecutive such ticks it stops and says so, rather than
# calling `onMapsApply` once a second forever.

proc numDrift(name: string; want, got: float): string =
  ## "" when the mirror agrees; otherwise the disagreement, named.
  if near(want, got): "" else: name & " config=" & $want & " mirror=" & $got

proc mirrorDrift(): string =
  ## "" when the live draw mirror agrees with config.json; otherwise a line
  ## naming the disagreement. NEGATIVE-shaped: it can only be non-empty when a
  ## stored value is provably not in force.
  let cfgEnabled = asBool(setting("enabled"), false)
  if cfgEnabled != gEnabled:
    return "config enabled=" & $cfgEnabled & " but this instance holds gEnabled=" &
           $gEnabled
  if not gHudOn:
    # NO DRAW PARTICIPANT -- and this used to `return ""` here, unconditionally,
    # which made the whole ledger a check that cannot fail. The C mirror is a
    # plain struct in this process: every `hudLive*` getter reads it whether or
    # not a draw participant is registered, so there was never a reason to stop
    # comparing. The cost of stopping was concrete: with gHudOn false (which is
    # exactly the state "every HUD surface is off in config"), an edit that
    # turned a surface back on -- spatialMode, indicators, the anchor, any
    # numeric -- produced NO drift, so no reconcile fired, so the edit was
    # stored and never applied until relaunch. That is the stored-but-inert
    # defect this ledger exists to catch, and the ledger was blind to it in
    # precisely the state where it was most likely.
    #
    # The one thing that genuinely cannot be compared without a participant is
    # nothing at all, so the walk simply continues below.
    if (not cfgEnabled) and hudLiveEnabled():
      return "config enabled=false, no draw participant, mirror enabled=ON"
  let live = cfgEnabled and gFeedRunning
  # WHAT CONFIG ASKS FOR, read by the SAME code the apply path uses. Reading it
  # a second, hand-written way here is how `radarSize` came to be storable and
  # inert: the boolean comparison below noticed nothing, so the reconcile never
  # fired, so no numeric edit ever reached the mirror.
  var w = HudOpts()
  readOpts(w)
  let wantMode = (if live: w.mode else: ModeOff)
  let wantInd = w.indicators and live
  if hudLiveEnabled() != live or hudLiveMode() != wantMode or
     hudLiveIndicators() != wantInd:
    return "config(enabled=" & $live & " mode=" & modeName(wantMode) &
           " ind=" & $wantInd & ") vs mirror(enabled=" & $hudLiveEnabled() &
           " mode=" & modeName(hudLiveMode()) &
           " ind=" & $hudLiveIndicators() & ")"

  # EVERY NUMERIC, compared against the LIVE MIRROR -- the struct the render
  # thread dereferences -- and not against a copy of our own last write. A
  # setting with no line here is a setting that can be stored and never applied,
  # so adding one to the schema without adding it here is the bug, not an
  # omission. `near` tolerates float round-tripping through JSON and nothing
  # else; the clamps live in the C setters, so a value the mirror clamped shows
  # up as PERSISTENT drift and the reconcile self-disables and says so rather
  # than re-applying forever.
  var d = ""
  d = numDrift("mapX", w.mapX, hudLivePaneX());            if d.len > 0: return d
  d = numDrift("mapY", w.mapY, hudLivePaneY());            if d.len > 0: return d
  d = numDrift("mapSize", w.mapSize, hudLivePaneSize());   if d.len > 0: return d
  d = numDrift("mapSpanM", w.mapSpanM, hudLivePaneSpan()); if d.len > 0: return d
  d = numDrift("radiusM", w.radiusM, hudLiveRadius());     if d.len > 0: return d
  d = numDrift("zoom", w.zoom, hudLiveZoom());             if d.len > 0: return d
  d = numDrift("opacity", w.opacity, hudLiveOpacity());    if d.len > 0: return d
  d = numDrift("contactSize", w.contactPx, hudLiveContactPx())
  if d.len > 0: return d
  d = numDrift("fullscreenMargin", w.fsMargin, hudLiveFsMargin())
  if d.len > 0: return d
  d = numDrift("fullscreenSpanM", w.fsSpanM, hudLiveFsSpan())
  if d.len > 0: return d
  d = numDrift("fullscreenZoom", w.fsZoom, hudLiveFsZoom())
  if d.len > 0: return d
  d = numDrift("fullscreenOpacity", w.fsOpacity, hudLiveFsOpacity())
  if d.len > 0: return d
  d = numDrift("widgetBorderPx", w.borderPx, hudLiveBorderPx())
  if d.len > 0: return d
  d = numDrift("widgetBackdropOpacity", w.backdropOpacity,
               hudLiveBackdropOpacity())
  if d.len > 0: return d
  # THE TEN THAT HAD NO LINE HERE. Each is pushed on every hudReconfigure and
  # each was invisible to this comparison, so none of them could ever MAKE the
  # reconcile fire -- an edit to any of them was applied only if some other key
  # happened to drift on the same tick. By the rule stated above, a schema entry
  # with no line here is a control that can be stored and never applied, so this
  # closes the audited gap rather than the one key that was reported.
  d = numDrift("screenW", w.screenW, hudLiveScreenW());     if d.len > 0: return d
  d = numDrift("screenH", w.screenH, hudLiveScreenH());     if d.len > 0: return d
  d = numDrift("radarSize", w.size, hudLiveRadarSize());    if d.len > 0: return d
  d = numDrift("radarX", w.x, hudLiveRadarX());             if d.len > 0: return d
  d = numDrift("radarY", w.y, hudLiveRadarY());             if d.len > 0: return d
  d = numDrift("indicatorInset", w.indicatorInset, hudLiveIndicatorInset())
  if d.len > 0: return d
  d = numDrift("indicatorHoldMs", float(w.indicatorHoldMs), float(hudLiveHoldMs()))
  if d.len > 0: return d
  d = numDrift("indicatorFadeMs", float(w.indicatorFadeMs), float(hudLiveFadeMs()))
  if d.len > 0: return d
  # The new key is drift-checked like the other two, so "the setting exists"
  # and "the setting reaches the renderer" cannot be confused for each other.
  d = numDrift("indicatorGraceMs", float(w.indicatorGraceMs),
               float(hudLiveGraceMs()))
  if d.len > 0: return d
  if w.showBots != hudLiveShowBots():
    return "showBots config=" & $w.showBots & " mirror=" & $hudLiveShowBots()
  if w.showPlayers != hudLiveShowPlayers():
    return "showPlayers config=" & $w.showPlayers &
           " mirror=" & $hudLiveShowPlayers()
  if w.anchor != hudLiveAnchor():
    return "widgetAnchor config=" & anchorName(w.anchor) &
           " mirror=" & anchorName(hudLiveAnchor())
  if w.radarAnchor != hudLiveRadarAnchor():
    return "radarAnchor config=" & anchorName(w.radarAnchor) &
           " mirror=" & anchorName(hudLiveRadarAnchor())
  if w.border != hudLiveBorder():
    return "widgetBorder config=" & $w.border & " mirror=" & $hudLiveBorder()
  if w.northPip != hudLiveNorthPip():
    return "northPip config=" & $w.northPip & " mirror=" & $hudLiveNorthPip()
  if w.mapGrid != hudLiveGrid():
    return "mapGrid config=" & $w.mapGrid & " mirror=" & $hudLiveGrid()
  if w.drawArt != hudLiveDrawArt():
    return "drawArt config=" & $w.drawArt & " mirror=" & $hudLiveDrawArt()
  if w.fsNorthUp != hudLiveFsNorthUp():
    return "fullscreenNorthUp config=" & $w.fsNorthUp &
           " mirror=" & $hudLiveFsNorthUp()
  if w.colBot != hudLiveColBot():
    return "colorBot config=" & $w.colBot & " mirror=" & $hudLiveColBot()
  if w.colPlayer != hudLiveColPlayer():
    return "colorPlayer config=" & $w.colPlayer &
           " mirror=" & $hudLiveColPlayer()
  # EVERY per-class toggle and colour, against the LIVE MIRROR. Ten more lines
  # for ten more settings, by the rule stated above: a schema entry with no
  # comparison here is a control that can be stored and never applied, and the
  # per-class toggles are exactly the shape of control that would go unnoticed
  # (a class you rarely see simply never appears, which looks like the raid).
  var cc = 0
  while cc < ClsCount:
    if w.clsShow[cc] != hudLiveClsShow(cc):
      return "show" & clsName(cc) & " config=" & $w.clsShow[cc] &
             " mirror=" & $hudLiveClsShow(cc)
    if w.clsCol[cc] != hudLiveClsColour(cc):
      return "color" & clsName(cc) & " config=" & $w.clsCol[cc] &
             " mirror=" & $hudLiveClsColour(cc)
    inc cc
  # The hotkey is not in the C mirror -- the ORDINAL this process resolved is
  # what the Unity tick polls, so that is what is compared.
  let wantKc = (if w.fsEnabled: keycodeOf(w.fsKey) else: -1)
  if wantKc != gFsKeyKc or w.fsEnabled != gFsHotkeysOn:
    return "fullscreenKey config=" & (if w.fsEnabled: w.fsKey else: "(hotkeys off)") &
           " kc=" & $wantKc & " but this instance polls kc=" & $gFsKeyKc &
           " hotkeys=" & $gFsHotkeysOn
  # THE ACTIVATION MODE, against the C mirror -- the value `mhud_fs_poll`
  # branches on. By the rule stated at the top of this ledger, a schema row with
  # no line here is a row that can be stored and never applied.
  if w.fsMode != hudLiveFsMode():
    return "fullscreenActivation config=" & activationNameOf(w.fsMode) &
           " mirror=" & activationNameOf(hudLiveFsMode())
  # `detail` and `enemyVisibility` are NOT compared here, and that is deliberate
  # rather than an omission:
  #   * `detail` is a PRESET that is fully resolved inside readOpts into
  #     drawArt / mapGrid / northPip. Those three ARE compared above, against the
  #     mirror, so a detail edit that failed to reach the renderer shows up as a
  #     drift on the layer it should have changed. Comparing the preset name as
  #     well would compare this process with its own arithmetic.
  #   * `enemyVisibility` has exactly one reachable resolved value on this build
  #     (`always`), so a comparison could not fail. The refusal in readOpts is
  #     what reports it, and the diag states the policy in force.
  result = ""

proc reportMasterGate() =
  ## ONE LINE PER STATE CHANGE, and the OFF line carries a number that can be
  ## wrong.
  ##
  ## The reported regression was "the maps OFF-toggle does not stop drawing".
  ## The gate itself is `mhud_draw`'s first branch, which returns before any
  ## `aowl_region_*` call -- but "I read the code and it returns early" is not
  ## evidence, and a claim in a log line ("maps: OFF") is not evidence either.
  ##
  ## So the OFF line quotes `hudGated()` minus its value at the moment of the
  ## edit: dispatches that ARRIVED at the draw callback and submitted ZERO
  ## primitives. That delta is falsifiable in the direction that matters. If the
  ## gate were not doing its job the callback would fall through instead of
  ## counting, and the delta would sit at 0 while frames ran -- which is exactly
  ## what this line then says, in as many words, rather than reporting silence
  ## as success.
  ##
  ## `hudPaneCalls`/`hudSelDrew` are the other half and are NOT restated here:
  ## they are the positive ledger the `renderer` diag line already carries.
  let on = gEnabled
  let nowState = (if on: 1 else: 0)
  if nowState == gMasterState: return
  let prev = gMasterState
  gMasterState = nowState
  if not on:
    gMasterGatedAt = hudGated()
    info ModName & ": master OFF (enabled=false) -- the draw callback's first " &
         "branch now returns before any region command. Gated dispatches so " &
         "far: " & $gMasterGatedAt & ". The next state change reports how many " &
         "arrived while off and drew nothing."
  else:
    let delta = hudGated() - gMasterGatedAt
    if prev == 0:
      if delta > 0'i64:
        info ModName & ": master OFF -> 0 draws/frame over " & $delta &
             " frame(s); master is ON again. Every one of those " & $delta &
             " dispatches reached the callback and submitted zero primitives."
      else:
        info ModName & ": master ON. NOTE: 0 dispatches were gated while it " &
             "was off -- so this says NOTHING about whether the off-gate " &
             "works. Either no frame was dispatched in that window (the menu, " &
             "or the region had no participant) or the gate was bypassed. " &
             "INCONCLUSIVE, not a pass."
    else:
      info ModName & ": master ON (enabled=true)."

proc reportPlacement() =
  ## The resolved widget rect, ONCE PER CHANGE, checked against the back buffer.
  ##
  ## `hudWidgetX/Y` is what the C renderer RESOLVED on the last drawn frame --
  ## not the configured inset, and not a number this process computed. The
  ## assertion is `rectInside`, the same negative the offline suite drives
  ## across both resolutions, applied here to the live value. An off-screen
  ## widget and a widget that never armed are indistinguishable on screen, and
  ## this line is what tells them apart.
  ##
  ## NOT a duplicate of the diag's `placement` line, which asks a DIFFERENT
  ## question: whether the resolved origin lands in the named corner's QUADRANT
  ## and differs from the configured inset. A rect can pass that and still hang
  ## off the bottom of the buffer (a mapSize larger than the screen does exactly
  ## that), and it can fail that while being entirely on-screen. Two properties,
  ## two checks; neither implies the other, and neither restates the other.
  if not gHudOn: return
  let measured = hudScreenMeasured() != 0'i32
  var scrW = float(gOpts.screenW)
  var scrH = float(gOpts.screenH)
  if measured:
    scrW = float(hudScreenW())
    scrH = float(hudScreenH())
  let rc = Rect(x: hudWidgetX(), y: hudWidgetY(),
                w: gOpts.mapSize, h: gOpts.mapSize)
  let inside = rectInside(rc, scrW, scrH)
  let line = anchorName(hudLiveAnchor()) & " " & rectText(rc) &
             " on " & $int(scrW) & "x" & $int(scrH) &
             (if measured: " (measured)" else: " (FALLBACK screenW/H -- the " &
              "region has not published a back-buffer size, so this verdict " &
              "is INCONCLUSIVE)") &
             (if inside: "  inside=yes" else: "  inside=NO")
  if line == gPlaceLast: return
  gPlaceLast = line
  if inside and measured:
    info ModName & ": placement " & line
  elif not measured:
    info ModName & ": placement " & line
  else:
    warn ModName & ": placement " & line & " -- the widget rect is NOT wholly " &
         "inside the back buffer, so part of it (or all of it) is off-screen. " &
         "In a corner mode this should be impossible; in `manual` it means " &
         "mapX/mapY/mapSize put it there. Pick a corner, or reduce mapSize."

proc onReconcileTick(payload: string): string =
  result = ""
  # Both of these run BEFORE the `gReconcileOff` early return and regardless of
  # `enabled`, deliberately: the master-gate line's whole job is to speak while
  # the feature is OFF, and a reconcile that has self-disabled is exactly when a
  # reader most needs the placement line.
  reportMasterGate()
  reportPlacement()
  if gReconcileOff: return
  let drift = mirrorDrift()
  if drift.len == 0:
    gReconcileFails = 0
    gLastDrift = ""
    return
  if drift == gLastDrift:
    inc gReconcileFails
    if gReconcileFails >= MaxReconcileFails:
      gReconcileOff = true
      warn ModName & ": the config/mirror reconcile ran " & $MaxReconcileFails &
           " times and the SAME disagreement is still there (" & drift &
           "), so applying is not what is failing -- it is disabled now rather " &
           "than running once a second forever. The maps diag `toggle` line " &
           "still reports the disagreement."
      return
  else:
    gReconcileFails = 0
  gLastDrift = drift
  inc gReconciles
  info ModName & ": RECONCILE #" & $gReconciles & " -- config.json changed " &
       "underneath the live mirror and no apply hook ran in this process " &
       "(the F12 POST is answered by the SERVER instance). " & drift
  onMapsApply("")

proc onLoad(): Status =
  gEnabled = asBool(setting("enabled"), false)
  gHz = asInt(setting("hz"), 10)
  if gHz < 1: gHz = 1
  if gHz > 30: gHz = 30
  gRadius = asFloat(setting("radiusM"), 120.0)
  # THE PHASE PROFILER. Flag-gated, DEFAULT OFF (CLAUDE.md 5). It installs no
  # detour, resolves no name and touches no game memory -- it is two QPC reads
  # per bracket -- but it is still off by default and still announces itself
  # when it is on, because an instrument nobody knows is running is an
  # instrument whose cost gets attributed to the thing it is measuring.
  gDiagVerbose = asBool(setting("diagVerbose"), false)
  let profOn = asBool(setting("profile"), false)
  gProfVerbose = asBool(setting("profileVerbose"), false)
  mpSetEnabled(if profOn: 1'i32 else: 0'i32)
  if profOn:
    info ModName & ": phase profiler ON. onMainTick is bracketed with " &
         "QueryPerformanceCounter at three DISJOINT levels (tick phases, " &
         "collect phases, per-entity phases), each summed against its own " &
         "parent bracket so the unbracketed remainder is named as UNEXPLAINED " &
         "rather than attributed. Every number is MICROSECONDS. It carries a " &
         "positive control of 512 integer adds through the same bracket -- " &
         "expected order 0.1-1.0us; 0.0us or milliseconds means the meter is " &
         "lying and the line is VOID. Emission is THROTTLED: the first " &
         "cycle, then every 5 minutes while the meter ADVANCES, and one " &
         "NOT-ADVANCED line every 60s while nothing runs to profile. Set " &
         "`profileVerbose` for one line every 2s."
  loadHudOpts()

  # Declared on BOTH sides, before the split -- see the block above `loadHudOpts`
  # for why that is what puts this client-side feature into the F12 nav.
  declareSettings(spatialSchema())
  # Register the hot-apply hook UNCONDITIONALLY and before the enabled gate, so
  # a live F12 edit is always either applied or honestly reported -- never
  # silently dropped, which is the whole of bug 1.
  onSettingsApplied(onMapsApply)
  discard serve("/aowlspt/settings/" & ModGuid, onSpatialSettings)

  if side() == sideServer:
    var why = ""
    if not registerRoutes(why):
      warn ModName & ": " & why
    else:
      success ModName & " " & ModVersion & " serving " & PageRoute &
              " -- " & $mapCount() & " maps, " & $layerCount() &
              " terrain layers, from " & mapsRoot()
    return Ok

  if side() != sideClient:
    return Ok

  # THE DIAGNOSTIC TIMER, registered FIRST and UNCONDITIONALLY -- before the
  # `enabled` gate below, not after it.
  #
  # It used to be registered at the very end of onLoad, i.e. only on the path
  # where the feature was already enabled and already armed. A session that
  # booted with `enabled=false` therefore emitted NO `maps diag` block at all,
  # for its entire life. That is what made the late-arm bug invisible: the one
  # instrument that could have said "config says ON and nothing is armed" was
  # itself gated on the feature working. A diag that only runs when the thing
  # works is a check that cannot fail (CLAUDE.md 9b), so it now runs always --
  # including in the disabled case it exists to describe.
  if not gDiagOn:
    if every(2000, onDiagTick) != Ok:
      warn ModName & ": the periodic diagnostic timer did NOT register, so this " &
           "mod cannot report whether it is drawing. Everything else may still " &
           "work -- but it will work silently, which is the failure mode this " &
           "timer exists to stop. Treat any later 'the radar does not appear' " &
           "as INCONCLUSIVE until this is fixed."
    else:
      gDiagOn = true

  # THE RECONCILE TIMER. Client-side, unconditional, and registered before the
  # `enabled` gate for the same reason the diag timer is: a session that booted
  # disabled is exactly the session in which an F12 edit has to be noticed.
  if not gReconcileOn:
    if every(ReconcilePeriodMs, onReconcileTick) != Ok:
      warn ModName & ": the config reconcile timer did NOT register. Settings " &
           "edits made from the F12 panel are answered by the SERVER instance " &
           "and will NOT reach this process's draw mirror, so a map turned off " &
           "in settings will stay on screen until the next launch."
    else:
      gReconcileOn = true

  if not gEnabled:
    info ModName & ": the live feed is OFF (config.json `enabled` is false), " &
         "so nothing here reads game memory. The map, the radar and the " &
         "indicators still open at " & PageRoute & " and will say plainly " &
         "that no feed is arriving. Turning `enabled` on in F12 LATE ARMS the " &
         "feed in place -- no relaunch, and it works mid-raid; watch for " &
         "'maps: LATE ARM' and for the 'arm' line in the maps diag block."
    return Ok

  # Arm the collector + draw through the shared armFeed() path (also used by the
  # hot-apply hook so enabled=false->true late-arms without a relaunch). A
  # collector-registration failure returns Ok here exactly as before: the map
  # page still opens; the diag timer above is what will report it.
  if not armFeed():
    return Ok
  gArmedAtBoot = true

  success ModName & " " & ModVersion & ": collector armed at " & $gHz &
          " Hz. " & feedStateText()
  Ok

proc onUnload(): Status =
  gEnabled = false
  if gHudOn:
    hudUnregister()
    gHudOn = false
  Ok

proc statusText*(): string =
  ## Read by the diagnostic route, so a human can tell the four states apart
  ## without reading the host log.
  "ticks=" & $gTicks & " published=" & $gPublished &
  " faults=" & $feedFaults() & " disabled=" & $feedDisabled() &
  " defect=" & feedDefect() &
  (if gLastErr.len > 0: " lastWriteError=" & gLastErr else: "") &
  " state=" & feedStateText() &
  " | hud " & (if gHudOn: hudStatusText() else: "not registered")

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideClient},
  onLoad = onLoad,
  onUnload = onUnload)
