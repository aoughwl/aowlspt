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
## What the browser costs is that the radar and the indicators are on a second
## screen rather than over the game. That is a real loss for those two and it
## is stated plainly in the report; see README for the exact thing that blocks
## the in-game version (it is ownership of the existing ESP draw region, not a
## capability this build lacks).
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
## `config.json`: `enabled` (false), `hz` (10), `radiusM` (120). With `enabled`
## false the client half registers no tick at all and never resolves the host
## export, so it cannot touch game memory even by accident. The SERVER half
## still serves the terrain and the calibration -- browsing the maps offline is
## harmless and needs no client.

import aowlspt
import aowlspt/server as sv
import aowlspt/sync
import sp / world
import sp / serve
import sp / page

const
  ModGuid* = "aowl.maps"
  ModName* = "Spatial"
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

proc onMainTick(payload: string): string =
  ## Unity's thread. Raw guarded reads into a preallocated buffer, and nothing
  ## else: no formatting, no file IO, no allocation beyond the bounded id
  ## labels. Everything expensive is the publish tick's job.
  if not gEnabled: return ""
  inc gTicks
  lockMod()
  collect(gSnap)
  gPending = true
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

  success ModName & " " & ModVersion & ": collector armed at " & $gHz &
          " Hz. " & feedStateText()
  Ok

proc onUnload(): Status =
  gEnabled = false
  Ok

proc statusText*(): string =
  ## Read by the diagnostic route, so a human can tell the four states apart
  ## without reading the host log.
  "ticks=" & $gTicks & " published=" & $gPublished &
  " faults=" & $feedFaults() & " disabled=" & $feedDisabled() &
  " defect=" & feedDefect() &
  (if gLastErr.len > 0: " lastWriteError=" & gLastErr else: "") &
  " state=" & feedStateText()

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer, sideClient},
  onLoad = onLoad,
  onUnload = onUnload)
