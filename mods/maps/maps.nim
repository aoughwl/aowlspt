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
var gFeedRunning = false
  ## True once the client-side collector and publish timer are actually
  ## registered (they are load-time registrations, so this cannot become true
  ## from the apply hook). The hook uses it to tell "toggled off live" (which it
  ## can honour now) apart from "toggled on live" (which still needs a relaunch).
var gHeadingOn = false
  ## The `heading` setting. Flag-gated and default OFF, like everything else
  ## here. When off, the measured heading is DISCARDED at publish time rather
  ## than merely ignored downstream, so "heading-up" and "north-up" remain one
  ## decision made in one place; hud.nim reads `rot` from a single variable and
  ## both the radar and the map pane follow it together.

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
  # Indicator LIFETIME. Defaults chosen so the ramp is visible rather than a
  # blink: 0.4 s at full alpha, then 1.6 s of fade -- two seconds from the last
  # refresh to gone. Both are clamped by the schema, and a 0 fade is legal and
  # means "vanish the instant the hold elapses".
  gOpts.indicatorHoldMs = asInt(setting("indicatorHoldMs"), 400)
  gOpts.indicatorFadeMs = asInt(setting("indicatorFadeMs"), 1600)
  gHeadingOn            = asBool(setting("heading"), false)

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
                              "line says which is happening. " &
                              "A bearing mark per contact on a ring around screen centre"),
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
  lockMod()
  collect(gSnap)
  gPending = true
  # The `heading` setting gates the ROTATION, not the measurement: the
  # heading is still read and still counted every collection, so
  # `mapsDiagText` can report whether it is live and MOVING even while the
  # surfaces are deliberately north-up. Gating the read instead would make
  # "the setting is off" and "the field is dead" produce the same diagnostic,
  # which is the ambiguity this mod keeps paying for.
  if not gHeadingOn: gSnap.hasHeading = false
  if gHudOn: hudPublish(gSnap)   # same thread as the region's draw; see sp/hud.nim
  # The ART, on the same thread and after the mirror is filled. Gated on a
  # VALIDATED local position: binding a map from a position that failed
  # `mm_pos_classify` would pick a map by a number we already know is wrong.
  # Gated on an ACTIVE RAID (bug 1), not merely a validated pose: a stale
  # borrowed GameWorld cache in the menu can validate a pose but is not a raid,
  # and binding art there would upload tiles and paint an overlay off-raid.
  # Only the MAP and RADAR panes render art; gate the tile IO/upload on one of
  # them being on (bug 4). An indicator-only or all-off config used to slurp and
  # upload a tile per tick for a surface nothing drew.
  if gHudOn and (gOpts.map or gOpts.radar) and
     activeRaid(gSnap) and gSnap.localIdx >= 0 and gSnap.localIdx < gSnap.n:
    artTick(gSnap.ents[gSnap.localIdx].x, gSnap.ents[gSnap.localIdx].z,
            gSnap.locationId)
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

var gDiagLast = ""
var gDiagTicks = 0'i64

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
  if not gHudOn:
    lRegion = "FAIL  the in-game HUD was never registered with the shared " &
              "region (radar, map and indicators are all off in config.json, " &
              "or registration was refused at load -- see the load line above)"
  elif not hudArmed():
    lRegion = "FAIL  registered, but the region is NOT armed, so the draw " &
              "callback can never fire. Set host flag `sharedRegion`"
  elif hudFrames() <= 0'i64:
    lRegion = "INCONCLUSIVE  registered and armed, but ZERO frames have been " &
              "dispatched to us yet -- nothing has called us even once"
  else:
    lRegion = "PASS  armed, " & $hudFrames() & " frame(s) dispatched to us"

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

  # 4. the draw itself, asserted on the FINISHED state: did primitives come out?
  var lDraw = ""
  if not gHudOn:
    lDraw = "INCONCLUSIVE  no HUD registered, so no draw was possible"
  elif hudFrames() <= 0'i64:
    lDraw = "INCONCLUSIVE  the callback has never been invoked"
  elif hudDrawn() <= 0'i64:
    lDraw = "FAIL  the callback ran " & $hudFrames() & " time(s) and drew " &
            "NOTHING every time. It returns immediately because no local " &
            "player position validated -- see `positions` above. This is the " &
            "reason the radar is not on screen"
  elif hudBlips() <= 0'i64:
    lDraw = "PASS  radar drawn on " & $hudDrawn() & " frame(s), but 0 blips " &
            "-- the ring is on screen with nothing in it"
  else:
    lDraw = "PASS  drawn on " & $hudDrawn() & " frame(s), " & $hudBlips() &
            " blip(s)"
  # BUG 2: dispatches skipped because a blocking UI surface (F12/Settings, F6,
  # F3) was open. Stated as its own countable clause so "hidden behind a panel"
  # never reads as the flicker failure. Zero when no panel was ever open.
  if hudMasked() > 0'i64:
    lDraw = lDraw & "; " & $hudMasked() & " dispatch(es) SKIPPED with an " &
            "overlay open (aowl_ui_overlay_mask != 0 -- map hidden behind a panel)"
  if hudGated() > 0'i64:
    lDraw = lDraw & "; " & $hudGated() & " dispatch(es) GATED OFF by the " &
            "master switch (enabled == 0 -- 0 primitives submitted, held frame " &
            "dropped)"

  # 5. the back buffer. A 0x0 screen puts every mark in the corner.
  var lScreen = ""
  if hudScreenMeasured() != 0'i32:
    lScreen = "PASS  " & $hudScreenW() & "x" & $hudScreenH() &
              " (measured back buffer)"
  else:
    lScreen = "INCONCLUSIVE  the region has not published a back-buffer size; " &
              "using the config fallback " & $hudScreenW() & "x" &
              $hudScreenH() & ". Edge-anchored marks may be misplaced"

  # 6. the projector -- indicators are north-up bearings without one.
  var lProj = ""
  if hudIndProjected() > 0'i64:
    lProj = "PASS  " & $hudIndProjected() & " indicator(s) projected"
  elif hudIndBearing() > 0'i64:
    lProj = "INCONCLUSIVE  " & $hudIndBearing() & " indicator(s) drawn as " &
            "BEARING RINGS; no projector is installed (nothing calls " &
            "aowl_region_set_projector), so they are a bearing and not a " &
            "projected screen position. They are no longer NORTH-UP whenever " &
            "a heading was measured -- the ring takes the same rotation the " &
            "radar does -- so a turning player now turns them; see `heading` " &
            "below for whether that is actually happening"
  else:
    lProj = "INCONCLUSIVE  no indicator has been drawn yet"

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
  elif hudIndFaded() == 0'i64:
    lLife = "FAIL  " & $hudIndExpired() & " track(s) were evicted but NOT ONE " &
            "was ever drawn at reduced alpha -- they are disappearing " &
            "abruptly instead of fading. The decay is not reaching the draw"
  else:
    lLife = "PASS  " & $hudIndFaded() & " indicator(s) drawn mid-fade and " &
            $hudIndExpired() & " removed after their window (" &
            $hudHoldMs() & "+" & $hudFadeMs() & "ms); " & $hudTracks() &
            " track(s) live"
  lLife = lLife & ". NOTE: these are NOT audio indicators. This mod " &
          "subscribes to no sound event of any kind; every indicator is one " &
          "live entry of GameWorld.AllAlivePlayersList, refreshed every " &
          "collection. An indicator that persists for a contact that is still " &
          "present is the FEED working as built, not a failed decay"
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
    lPerf = "last=" & $hudDrawUsLast() & "us avg=" & $hudDrawUsAvg() &
            "us peak=" & $hudDrawUsPeak() & "us  tiles/frame=" & $hudTilesLast() &
            " (budget " & $gOpts.budgetUs & "us; the region throttles this " &
            "participant after 8 consecutive overruns)"

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
  var lToggle = ""
  if not gHudOn:
    lToggle = "INCONCLUSIVE  no HUD is registered, so there is no live mirror " &
              "to compare config.json against"
  else:
    let cfgEnabled = asBool(setting("enabled"), false)
    let cfgMap     = asBool(setting("hudMap"), false)
    let cfgRadar   = asBool(setting("hudRadar"), true)
    let cfgInd     = asBool(setting("hudIndicators"), false)
    # The mirror's per-surface flags are config ANDed with `live`, so the only
    # legal disagreement is mirror=off while config=on (the feed is not
    # running). mirror=ON while config=off is ALWAYS a defect: it means an edit
    # was persisted and never applied, and the player is looking at art they
    # switched off.
    var leaked: seq[string] = @[]
    if (not cfgEnabled) and hudLiveEnabled(): leaked.add "enabled"
    if (not cfgMap)     and hudLiveMap():     leaked.add "hudMap"
    if (not cfgRadar)   and hudLiveRadar():   leaked.add "hudRadar"
    if (not cfgInd)     and hudLiveIndicators(): leaked.add "hudIndicators"
    var mirrorTxt = "config(enabled=" & $cfgEnabled & " map=" & $cfgMap &
                    " radar=" & $cfgRadar & " ind=" & $cfgInd & ")" &
                    " vs mirror(enabled=" & $hudLiveEnabled() &
                    " map=" & $hudLiveMap() & " radar=" & $hudLiveRadar() &
                    " ind=" & $hudLiveIndicators() & ")"
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

  result = "maps diag:\n" &
           "  region       : " & lRegion & "\n" &
           "  world        : " & lWorld  & "\n" &
           "  raid         : " & lRaid   & "\n" &
           "  positions    : " & lPos    & "\n" &
           "  toggle       : " & lToggle & "\n" &
           "  draw         : " & lDraw   & "\n" &
           "  drawCost     : " & lPerf   & "\n" &
           "  screen       : " & lScreen & "\n" &
           "  projector    : " & lProj   & "\n" &
           "  heading      : " & lHdg    & "\n" &
           "  indLifetime  : " & lLife   & "\n" &
           "  art          : " & lArt    & "\n" &
           "  feed         : ticks=" & $gTicks & " published=" & $gPublished &
             " faults=" & $feedFaults() & " defect=" & feedDefect()

proc onDiagTick(payload: string): string =
  ## Always announces. The FIRST tick prints unconditionally -- so a session in
  ## which everything is broken from the start still gets a full report -- and
  ## afterwards it prints on any CHANGE, plus a periodic heartbeat so a
  ## long-running stuck state cannot scroll away and be forgotten.
  inc gDiagTicks
  let text = mapsDiagText()
  if gDiagLast.len == 0 or text != gDiagLast or (gDiagTicks mod 30'i64) == 0'i64:
    gDiagLast = text
    info text
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
  if (gOpts.radar or gOpts.indicators or gOpts.map) and not gHudOn:
    hudInit(gOpts)
    var whyHud = ""
    if hudRegister(gOpts, whyHud):
      gHudOn = true
      if hudArmed():
        success ModName & ": in-game HUD registered with the shared region " &
                "and the region is ARMED -- radar=" & $gOpts.radar &
                " map=" & $gOpts.map & " indicators=" & $gOpts.indicators
      else:
        warn ModName & ": in-game HUD registered, but the shared region is " &
             "NOT armed, so the callback will never fire and nothing will be " &
             "drawn. Set the host flag `sharedRegion` in aowlspt-host.json. " &
             "This is not 'the radar is off' -- it is 'nothing is dispatching'."
    else:
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
  let nowEnabled = asBool(setting("enabled"), false)
  loadHudOpts()                       # refresh gOpts + gHeadingOn from config
  let live = nowEnabled and gFeedRunning
  hudReconfigure(gOpts, live)         # next frame honours it; no position reset
  # A MAPS-OWNED TRACE, unconditional and BEFORE the verdict branches below
  # (bug 2). The earlier apply hook left no line of its own in the host log, so
  # "the toggle did nothing" and "the hook never fired" were indistinguishable.
  # This prints the exact values just pushed into the C mirror the draw callback
  # reads every frame -- `mapOn`/`radarOn`/`indicatorsOn` are each ANDed with
  # `live`, so an off edit shows the surface at 0 here and the NEXT draw frame
  # honours it (0 tiles / 0 blips). This is the finished-state assertion the fix
  # is judged on: not "apply returned ok" but "the mirror now reads off".
  info "maps: apply " & (if key.len > 0: key else: "(all)") &
       " -> config hudMap=" & $gOpts.map & " hudRadar=" & $gOpts.radar &
       " indicators=" & $gOpts.indicators & " enabled=" & $nowEnabled &
       " live=" & $live & " -> mirror pushed mapOn=" &
       $(gOpts.map and live) & " radarOn=" & $(gOpts.radar and live) &
       " indicatorsOn=" & $(gOpts.indicators and live)
  if key == "enabled":
    gEnabled = nowEnabled             # gates onMainTick/onPublishTick live
    if nowEnabled:
      # HOT-START (bug: this used to be a relaunch-only no-op --
      # settingAppliesOnRestart). Arm the SAME collector + draw path onLoad uses,
      # idempotently via armFeed(). gEnabled is set first so the freshly
      # registered onMainTick/onPublishTick do real work on their first fire. The
      # in-raid lifecycle gate in hud.nim still owns whether anything DRAWS, so
      # this only makes the map begin drawing on the next IN-RAID frame; outside a
      # raid the feed arms and waits. Re-push the mirror with live=true, because
      # the hudReconfigure above ran while gFeedRunning was still false (live=0).
      if armFeed():
        hudReconfigure(gOpts, gEnabled and gFeedRunning)
        settingApplied("feed HOT-STARTED without relaunch -- collector armed" &
          (if gHudOn: "; in-game HUD registered" else: "") &
          "; draws on the next in-raid frame (in-raid lifecycle gate applies)")
      else:
        settingIgnored("could not arm the live collector; see the warning above")
    else:
      # true->false: gEnabled now gates the collector ticks to no-ops, and the
      # hudReconfigure above already pushed live=false into the mirror (mapOn=
      # radarOn=indicatorsOn=0), so the very next draw frame submits nothing. The
      # timers and the region participant stay registered but idle -- a later
      # re-enable hot-starts through armFeed's idempotent guards.
      settingApplied("feed OFF -- HUD blanked (0 tiles, 0 blips)")
    return
  if not (gEnabled and gFeedRunning and
          (gOpts.radar or gOpts.indicators or gOpts.map)):
    settingIgnored("stored; nothing is drawn because the feed is off or every " &
      "HUD surface (radar/map/indicators) is off")
    return
  settingApplied("radar=" & $gOpts.radar & " map=" & $gOpts.map &
                 " indicators=" & $gOpts.indicators & " heading=" & $gHeadingOn &
                 (if gHeadingOn: " (heading-up: art refuses, grid+blips rotate)"
                  else: " (north-up: baked art drawn)"))

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

  if not gEnabled:
    info ModName & ": the live feed is OFF (config.json `enabled` is false), " &
         "so nothing here reads game memory. The map, the radar and the " &
         "indicators still open at " & PageRoute & " and will say plainly " &
         "that no feed is arriving."
    return Ok

  # Arm the collector + draw through the shared armFeed() path (also used by the
  # hot-apply hook so enabled=false->true hot-starts without a relaunch). A
  # collector-registration failure returns Ok here exactly as before: the map
  # page still opens; the diag timer below is what will report it.
  if not armFeed():
    return Ok

  # THE DIAGNOSTIC TIMER. Registered LAST and unconditionally, because it is
  # the thing that explains every branch above -- including the branches that
  # returned early. Its failure to register is itself announced: a diag that
  # quietly never runs would reproduce the exact bug it exists to prevent.
  if every(2000, onDiagTick) != Ok:
    warn ModName & ": the periodic diagnostic timer did NOT register, so this " &
         "mod cannot report whether it is drawing. Everything else may still " &
         "work -- but it will work silently, which is the failure mode this " &
         "timer exists to stop. Treat any later 'the radar does not appear' " &
         "as INCONCLUSIVE until this is fixed."

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
