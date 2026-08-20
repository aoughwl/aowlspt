## Admin / cheat menu -- a native, client-side admin panel for post-1.0 EFT.
##
## ---------------------------------------------------------------------------
## WHAT THIS IS, AND THE ONE RULE THAT SHAPES ALL OF IT
## ---------------------------------------------------------------------------
##
## Press **F6** to toggle an in-game admin menu with independently togglable
## cheat modes. ESP and God mode are ON by default; the rest are off. Every mode
## is a toggle the menu owns and this file reads.
##
## The rule that shapes every line below: **a managed IL2CPP call may only be
## made from Unity's own thread.** Calling one from the host's thread crashes
## this client, established repeatedly across this repo. So all of this mod's
## per-frame work -- reading the world for ESP, freezing health for God mode,
## capping stamina, and (where it lands) drawing -- runs inside `everyMain`,
## which the host drains from a per-frame game method, i.e. on Unity's thread.
## And it runs there **only after** the host confirms that drain has actually
## fired (`aowlspt.host::main_thread` -> `bound:true`); until then this mod
## touches nothing managed. That gate is the whole safety story: no bound Unity
## thread, no cheat, no crash -- the menu still opens and every mode reads
## "unavailable".
##
## ---------------------------------------------------------------------------
## THE SPLIT: WHAT IS REAL, WHAT IS PENDING
## ---------------------------------------------------------------------------
##
## Everything here renders and runs through the **game's own runtime on Unity's
## thread** -- there is deliberately no use of the host's hand-drawn D3D11
## overlay. That has a consequence worth stating up front, because half of this
## file depends on it:
##
##   * **Runs now (managed writes/reads on Unity's thread):** the toggle
##     framework, F6/arrow/enter input (via `GetAsyncKeyState`, which is not a
##     managed call and is safe from any thread), God mode (incoming-damage
##     suppression on the local player), infinite stamina, and the ESP *data*
##     pass -- walking the world, projecting every player to screen with the
##     camera's own view-projection matrix. Each is armed only when every
##     binding it needs resolved, and reports "unavailable" otherwise.
##
##   * **Pending a render-phase Unity hook:** the actual *pixels*. Native ESP
##     lines and the F6 menu need to run during the engine's render/GUI phase to
##     paint -- `GL` immediate mode only draws inside camera rendering, and there
##     is no `MonoBehaviour`/`OnGUI` to attach post-1.0 (see docs/IL2CPP.md).
##     The host's main-thread drain fires in the *Update* phase, not the render
##     phase, so a `GL` call from here is on the right thread at the wrong time.
##     `adm/render` binds the engine's drawing surface and is called every frame,
##     but it can only paint once the bridge (or a detour of a render-phase
##     method) gives this mod a callback during rendering. That interface is
##     defined in `adm/render.nim` and this file codes against it; what is
##     missing is the host delivering the callback in the render phase. Until
##     then the ESP geometry and menu layout are computed and logged every
##     frame, and `adminDiag()` reports exactly what bound and what did not.
##
## **Nothing here has been run against BSG's live client.** Every `EFT.`/Unity
## name is from the pre-1.0 surface; post-1.0 is a different build. A wrong name
## is a refused binding with a `why` line and a mode that reads "unavailable",
## never a wrong write or a crash. `adminDiag()` prints every binding's own
## account of itself.

import std/strutils
import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import aowlspt/game
import aowlspt/server
import aowlspt/settings
import aowlspt/json

import "adm" / state
import "adm" / world
import "adm" / cheats
import "adm" / render

const
  ModGuid = "aowl.admin"
  ModName = "Admin Menu"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"

# ---------------------------------------------------------------------------
# Configuration -- the default toggle states, mirrored by the F12 schema
# ---------------------------------------------------------------------------
#
# Filled in `onLoad`, never at declaration: a nimony `--app:lib` global
# initialised by a call is left zeroed (docs/MODDING.md), and these are read
# through the host.

var cfgEspDefault = true
var cfgGodDefault = true
var cfgStaminaDefault = false
var cfgNoRecoilDefault = false
var cfgNoWeightDefault = false
var cfgInstaHealDefault = false
var cfgAmmoDefault = false
var cfgThermalDefault = false
var cfgNightVisDefault = false
var cfgFlyDefault = false
var cfgTeleportDefault = false
var cfgTimeDefault = false
var cfgEspMaxDistance = 400.0

proc cfgBool(key: string; default: bool): bool =
  setting(key).asBool(default)

proc loadConfig() =
  cfgEspDefault = cfgBool("esp", true)
  cfgGodDefault = cfgBool("godmode", true)
  cfgStaminaDefault = cfgBool("infiniteStamina", false)
  cfgNoRecoilDefault = cfgBool("noRecoil", false)
  cfgNoWeightDefault = cfgBool("noWeight", false)
  cfgInstaHealDefault = cfgBool("instantHeal", false)
  cfgAmmoDefault = cfgBool("unlimitedAmmo", false)
  cfgThermalDefault = cfgBool("thermalVision", false)
  cfgNightVisDefault = cfgBool("nightVision", false)
  cfgFlyDefault = cfgBool("fly", false)
  cfgTeleportDefault = cfgBool("teleport", false)
  cfgTimeDefault = cfgBool("timeOfDay", false)
  cfgEspMaxDistance = setting("espMaxDistance").asFloat(400.0)

proc seedToggles() =
  ## The config values are the initial toggle states. After the menu changes a
  ## toggle it lives in `adm/state`, not here.
  setToggle(tgEsp, cfgEspDefault)
  setToggle(tgGod, cfgGodDefault)
  setToggle(tgStamina, cfgStaminaDefault)
  setToggle(tgNoRecoil, cfgNoRecoilDefault)
  setToggle(tgNoWeight, cfgNoWeightDefault)
  setToggle(tgInstaHeal, cfgInstaHealDefault)
  setToggle(tgAmmo, cfgAmmoDefault)
  setToggle(tgThermal, cfgThermalDefault)
  setToggle(tgNightVis, cfgNightVisDefault)
  setToggle(tgFly, cfgFlyDefault)
  setToggle(tgTeleport, cfgTeleportDefault)
  setToggle(tgTime, cfgTimeDefault)

# ---------------------------------------------------------------------------
# The F12 settings schema
# ---------------------------------------------------------------------------
#
# Declared so the modes also appear on the F12 settings screen. NOTE: a
# client-only mod's route is not served on the backend, so its F12 page may read
# "could not read this page" (docs/SETTINGS.md) -- the authoritative control is
# the F6 menu. The schema is still declared, both for completeness and for the
# day the client host serves its own settings surface.

proc adminSchema(): seq[Setting] =
  result = @[
    boolSetting("esp", "ESP", true, category = "Visuals",
                description = "Boxes, distance and side-colour on every player"),
    boolSetting("godmode", "God mode", true, category = "Combat",
                description = "Suppress incoming damage to the local player"),
    boolSetting("infiniteStamina", "Infinite stamina", false,
                category = "Movement"),
    boolSetting("noRecoil", "No recoil / sway", false, category = "Combat"),
    boolSetting("noWeight", "No weight", false, category = "Movement",
                implemented = false,
                description = "Read; the encumbrance write is not bound yet"),
    boolSetting("instantHeal", "Instant heal", false, category = "Combat",
                implemented = false,
                description = "Read; per-body-part heal not bound yet"),
    boolSetting("unlimitedAmmo", "Unlimited ammo", false, category = "Combat",
                implemented = false,
                description = "Read; magazine write not bound yet"),
    boolSetting("thermalVision", "Thermal vision", false, category = "Visuals",
                implemented = false,
                description = "Read; vision-mode toggle not bound yet"),
    boolSetting("nightVision", "Night vision", false, category = "Visuals",
                implemented = false,
                description = "Read; vision-mode toggle not bound yet"),
    boolSetting("fly", "Fly / noclip", false, category = "Movement",
                implemented = false,
                description = "Read; movement-state override not bound yet"),
    boolSetting("teleport", "Teleport to marker", false, category = "Movement",
                implemented = false,
                description = "Read; position write not bound yet"),
    boolSetting("timeOfDay", "Set time of day", false, category = "World",
                implemented = false,
                description = "Read; game-date-time write not bound yet"),
    floatSetting("espMaxDistance", "ESP max distance (m)", 400.0,
                 lo = 10.0, hi = 2000.0, step = 10.0, category = "Visuals")]

proc onAdminSettings(url, body, session: string): string =
  if body.len > 0 and applySettingFromBody(body) == Ok:
    loadConfig()
    seedToggles()
  result = declaredSchemaJson().text

# ---------------------------------------------------------------------------
# The main-thread gate
# ---------------------------------------------------------------------------

var gBound = false
var gAskedAt = 0'i64

proc mainThreadBound(nowMs: int64): bool =
  ## True once the host's per-frame drain has actually fired on Unity's thread.
  ## Re-asked every two seconds until affirmative; never asked again after.
  if gBound:
    return true
  if nowMs - gAskedAt < 2000'i64 and gAskedAt != 0'i64:
    return false
  gAskedAt = nowMs
  var raw = ""
  if call("aowlspt.host::main_thread", "[]", raw) != Ok:
    return false
  gBound = asBool(field(raw, "bound"), false)
  result = gBound

# ---------------------------------------------------------------------------
# The per-frame tick, on Unity's thread
# ---------------------------------------------------------------------------

var gTick = 0'i64
var gReported = false

proc everyFrame(payload: string): string =
  ## Runs once per drain on the game's thread -- but only touches the runtime
  ## once the drain is confirmed. Everything managed is behind `gBound`.
  gTick = gTick + 1
  let now = nowMs()

  # Input is a Win32 read; safe on any thread, so it runs whether or not the
  # runtime is up. This is what makes the menu open even with no game world.
  pollInput()

  if not mainThreadBound(now):
    return ""

  # From here down is Unity's thread, confirmed. Bind the runtime once.
  if not worldReady():
    discard openWorld()
    return ""

  # Collect the world snapshot when anything that reads it is on: ESP or the
  # menu want the entity list, and God mode / stamina want the local-player
  # pointer the same pass resolves. Cheap-refused if nothing bound.
  if toggleOn(tgEsp) or menuVisible() or toggleOn(tgGod) or toggleOn(tgStamina):
    collectEsp(cfgEspMaxDistance)

  # Apply the frame-resident cheats. Each is a no-op unless its toggle is on and
  # its binding resolved; each sets its own capability bit.
  applyCheats()

  # Hand the frame to the renderer. Native drawing paints only in the render
  # phase (pending); until then this computes and logs the geometry.
  renderFrame()

  if not gReported and gTick > 120:
    gReported = true
    info "admin: " & adminDiag()

  result = ""

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  loadConfig()
  seedToggles()
  declareSettings(adminSchema())
  discard serve("/aowlspt/settings/" & ModGuid, onAdminSettings)

  # God mode's damage hook is installed once, at load, on Unity's thread when it
  # fires -- but the *hook registration* itself is a host call, safe here.
  installGodmode()

  if side() == sideClient:
    if everyMain(everyFrame) == Ok:
      info ModName & " " & ModVersion &
           " loaded; F6 opens the admin menu (ESP + God mode on by default)"
    else:
      warn ModName & ": the host has no Unity-thread drain to run on; " &
           "cheats stay off (menu input still works)"
  else:
    info ModName & " loaded on a non-client side; it does nothing here"
  result = Ok

proc onUnload(): Status =
  discard stopMainRepeats()
  removeGodmode()
  result = Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
