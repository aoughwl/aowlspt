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

import aowlspt
import aowlspt/server as sv
import aowlspt/sync
import aowlspt/settings   # the F12 schema this mod declares -- see `spatialSchema`
import sp / world
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

proc loadHudOpts() =
  gOpts.radar       = asBool(setting("hudRadar"), true)
  gOpts.indicators  = asBool(setting("hudIndicators"), false)
  gOpts.radiusM     = gRadius
  gOpts.screenW     = asFloat(setting("screenW"), 1920.0)
  gOpts.screenH     = asFloat(setting("screenH"), 1080.0)
  gOpts.size        = asFloat(setting("radarSize"), 220.0)
  gOpts.x           = asFloat(setting("radarX"), 24.0)
  gOpts.y           = asFloat(setting("radarY"), 24.0)
  gOpts.showBots    = asBool(setting("showBots"), true)
  gOpts.showPlayers = asBool(setting("showPlayers"), true)
  gOpts.budgetUs    = asInt(setting("hudBudgetUs"), 400)
  gOpts.order       = 500
  # The MAP pane. Bigger than the radar, wider span, its own toggle -- three
  # separate deliverables, three separate switches, so a player who wants the
  # radar and not a half-screen map is not forced to take both.
  gOpts.map         = asBool(setting("hudMap"), false)
  gOpts.mapX        = asFloat(setting("mapX"), 320.0)
  gOpts.mapY        = asFloat(setting("mapY"), 120.0)
  gOpts.mapSize     = asFloat(setting("mapSize"), 720.0)
  gOpts.mapSpanM    = asFloat(setting("mapSpanM"), 500.0)
  gOpts.mapGrid     = asInt(setting("mapGrid"), 8)
  gOpts.indicatorInset = asFloat(setting("indicatorInset"), 48.0)

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

    boolSetting("hudRadar", "In-game radar", true, category = "HUD",
                description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). Draw the radar over the game, via the shared region"),
    boolSetting("hudIndicators", "Direction indicators", false, category = "HUD",
                description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). A marker per contact, clamped to the screen " &
                              "edge in its direction. Camera-relative when the " &
                              "region has a projector installed; a NORTH-UP " &
                              "bearing ring when it does not, and the status " &
                              "line says which is happening"),
    floatSetting("radarSize", "Radar size (px)", 220.0, lo = 64.0, hi = 640.0,
                 step = 8.0, category = "HUD"),
    floatSetting("radarX", "Radar X (px)", 24.0, lo = 0.0, hi = 4096.0,
                 step = 4.0, category = "HUD"),
    floatSetting("radarY", "Radar Y (px)", 24.0, lo = 0.0, hi = 4096.0,
                 step = 4.0, category = "HUD"),
    boolSetting("hudMap", "In-game map", false, category = "Map",
                description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). A large top-down map pane drawn over the game " &
                              "by the shared region. Player-centred: anchoring " &
                              "it to the level needs the pocketmap pyramid's " &
                              "world origin, which nothing has measured"),
    floatSetting("mapSize", "Map size (px)", 720.0, lo = 128.0, hi = 2160.0,
                 step = 16.0, category = "Map"),
    floatSetting("mapX", "Map X (px)", 320.0, lo = 0.0, hi = 7680.0,
                 step = 8.0, category = "Map"),
    floatSetting("mapY", "Map Y (px)", 120.0, lo = 0.0, hi = 4320.0,
                 step = 8.0, category = "Map"),
    floatSetting("mapSpanM", "Map span (m across)", 500.0, lo = 50.0,
                 hi = 4000.0, step = 25.0, category = "Map",
                 description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). How much world the pane covers edge to edge"),
    intSetting("mapGrid", "Map grid divisions", 8, lo = 0, hi = 32,
               category = "Map",
               description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). A scale reference, not scenery. There is no map " &
                             "ARTWORK: the region's command set is fill/box/" &
                             "line/text with no textured quad, so the " &
                             "pocketmap tiles cannot be submitted through it"),
    floatSetting("indicatorInset", "Indicator edge inset (px)", 48.0, lo = 8.0,
                 hi = 400.0, step = 4.0, category = "HUD",
                 description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). How far in from the screen edge an off-screen " &
                               "contact's marker is clamped"),
    boolSetting("showBots", "Show bots", true, category = "HUD"),
    boolSetting("showPlayers", "Show players", true, category = "HUD"),
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

    boolSetting("heading", "Rotate radar to facing", false, category = "HUD",
                implemented = false,
                description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). Read; sp/world.nim measures no heading yet, so " &
                              "the radar AND the map pane are north-up and say " &
                              "so rather than rotating by a guessed zero. Both " &
                              "take their rotation from one place, so a " &
                              "measured heading turns both heading-up at once"),
    boolSetting("markers", "Loot / extract / corpse / quest markers", false,
                category = "HUD", implemented = false,
                description = "Specified from the pre-1.0 BepInEx map/radar mods (no upstream code carried; map art and calibration provenance in mods/maps/data/maps/README.md). Not collected: no field offset for any of those " &
                              "lists has been measured on this build"),
  ]

proc onSpatialSettings(url, body, session: string): string =
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
  result = declaredSchemaReply(st).text

proc onMainTick(payload: string): string =
  ## Unity's thread. Raw guarded reads into a preallocated buffer, and nothing
  ## else: no formatting, no file IO, no allocation beyond the bounded id
  ## labels. Everything expensive is the publish tick's job.
  if not gEnabled: return ""
  inc gTicks
  lockMod()
  collect(gSnap)
  gPending = true
  if gHudOn: hudPublish(gSnap)   # same thread as the region's draw; see sp/hud.nim
  unlockMod()
  result = ""

proc onPublishTick(payload: string): string =
  ## The mod's own timer thread. Formatting and file IO live here and only here.
  if not gEnabled: return ""
  lockMod()
  let have = gPending
  gPending = false
  var body = ""
  if have:
    body = snapshotJson(gSnap, feedStateText(), feedDefect(), feedFaults(),
                        feedDisabled(), gRadius)
  unlockMod()
  if not have: return ""
  var err = ""
  if writeSnapshot(body, err):
    inc gPublished
  else:
    gLastErr = err
  result = ""

proc onLoad(): Status =
  gEnabled = asBool(setting("enabled"), false)
  gHz = asInt(setting("hz"), 10)
  if gHz < 1: gHz = 1
  if gHz > 30: gHz = 30
  gRadius = asFloat(setting("radiusM"), 120.0)
  loadHudOpts()

  # Declared on BOTH sides, before the split -- see the block above `loadHudOpts`
  # for why that is what puts this client-side feature into the F12 nav.
  declareSettings(spatialSchema())
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

  if not gEnabled:
    info ModName & ": the live feed is OFF (config.json `enabled` is false), " &
         "so nothing here reads game memory. The map, the radar and the " &
         "indicators still open at " & PageRoute & " and will say plainly " &
         "that no feed is arriving."
    return Ok

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
    return Ok
  if every(1000 div gHz, onPublishTick) != Ok:
    warn ModName & ": collector registered but the publish timer did not; " &
         "positions are being read and nothing is being written."
    return Ok

  # The in-game draw. It rides the SHARED region (abi/aowlspt_region.h) as one
  # more participant on the existing PreloaderUI::Update rider chain -- it does
  # NOT add a second detour, and it does not borrow mods/admin's private HUD.
  # Registration and ARMING are reported separately on purpose: registration
  # always succeeds, and a registered participant on an unarmed region simply
  # never fires. Flattening those two into "the radar is on" would be a claim
  # that cannot be falsified.
  if gOpts.radar or gOpts.indicators:
    hudInit(gOpts)
    var whyHud = ""
    if hudRegister(gOpts, whyHud):
      gHudOn = true
      if hudArmed():
        success ModName & ": in-game HUD registered with the shared region " &
                "and the region is ARMED -- radar=" & $gOpts.radar &
                " indicators=" & $gOpts.indicators
      else:
        warn ModName & ": in-game HUD registered, but the shared region is " &
             "NOT armed, so the callback will never fire and nothing will be " &
             "drawn. Set the host flag `sharedRegion` in aowlspt-host.json. " &
             "This is not 'the radar is off' -- it is 'nothing is dispatching'."
    else:
      warn ModName & ": the shared region refused the in-game HUD: " & whyHud &
           ". The map page still works; the radar and the indicators do not."

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
