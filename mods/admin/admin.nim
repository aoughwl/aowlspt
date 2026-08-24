## Admin / cheat menu -- a fully native, client-side admin panel for post-1.0
## Escape From Tarkov (IL2CPP build 1.1.0.1.46777).
##
## ---------------------------------------------------------------------------
## THE ARCHITECTURE, AND WHY IT IS THIS ONE
## ---------------------------------------------------------------------------
##
## Press **F6** for an in-game admin menu of togglable cheat modes; ESP and God
## mode default ON, the rest off. It is fully native and uses **no** managed
## Unity-thread bridge, because on this client build that bridge is dead: the
## anti-cheat strips the per-frame `MethodInfo.methodPointer`, so calling a
## managed game method is not available. Two things still work, and this mod is
## built entirely on them:
##
##   * **Reading/writing object memory by field offset.** `il2cpp_field_get_offset`
##     is a metadata query, not a stripped method, so resolving a field's offset
##     and reading `*(T*)(object + offset)` works -- from any thread. That is the
##     ESP data pass (`adm/data.nim`) and the God mode / stamina writes.
##
##   * **Drawing inside the game's own `IDXGISwapChain::Present`.** The overlay
##     already hooks Present once; the ESP boxes and the F6 menu are drawn there
##     as a HUD on the frame (`abi/aowlspt_overlay.h` + `abi/aowlspt_admin.h`),
##     the same place Steam/Discord/RivaTuron and the graphics post-process draw.
##     This is a HUD, not the vetoed mod-manager panel.
##
## The two halves rendezvous through a named shared-memory region
## (`abi/aowlspt_admin.h`): this mod publishes the projected entities + toggles'
## capability into it (on the host's `on_update`, since a memory read needs no
## particular thread), and the overlay's Present hook reads it and draws. The F6
## keypress and menu navigation are handled in the overlay's WndProc, writing the
## toggles this mod then reads.
##
## ---------------------------------------------------------------------------
## WHAT IS REAL, WHAT NEEDS THE OFFSET DUMP
## ---------------------------------------------------------------------------
##
##   * **The whole native pipeline is real and complete:** shared region, the
##     Present-hook HUD (ESP boxes + F6 menu), the WndProc input, the publish
##     path, and the field-offset read/write framework.
##   * **The specific offsets/field names are the live-iteration parameters.**
##     `adm/data.nim` resolves them *by name* through reflection (so a correct
##     name yields the right offset for this build), and every one degrades to
##     "unavailable" on a miss -- ESP shows nothing, God mode is off, the menu
##     still opens. The names are the pre-1.0 surface and unconfirmed against
##     build 46777; the metadata dump (or a live probe) fills them in one place.
##     `adminDiag()`/the region's status line report exactly what resolved.
##
## Nothing here can crash the game: every read is address-checked, every mode is
## capability-gated, and an absent region or runtime is a no-op.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/settings
import aowlspt/json

import "adm" / shared
import "adm" / data

const
  ModGuid = "aowl.admin"
  ModName = "Admin Menu"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"

# ---------------------------------------------------------------------------
# Config -- the initial toggle states + ESP range
# ---------------------------------------------------------------------------

var cfgEspMaxDistance = 400.0

proc cfgBool(key: string; default: bool): bool =
  setting(key).asBool(default)

var gRegion: AdminRegion

proc applyConfigToggles() =
  ## config.json is the initial state at load. seedDefaults sets ESP+God on the
  ## first time any process maps the region; then this overlays the config so a
  ## fresh launch honours the file. After load the F6 menu owns the toggles.
  if gRegion == nil: return
  adminSeedDefaults(gRegion)
  setToggle(gRegion, admEsp,       cfgBool("esp", true))
  setToggle(gRegion, admGodmode,   cfgBool("godmode", true))
  setToggle(gRegion, admStamina,   cfgBool("infiniteStamina", false))
  setToggle(gRegion, admNoRecoil,  cfgBool("noRecoil", false))
  setToggle(gRegion, admNoWeight,  cfgBool("noWeight", false))
  setToggle(gRegion, admInstaHeal, cfgBool("instantHeal", false))
  setToggle(gRegion, admAmmo,      cfgBool("unlimitedAmmo", false))
  setToggle(gRegion, admThermal,   cfgBool("thermalVision", false))
  setToggle(gRegion, admNightVis,  cfgBool("nightVision", false))
  setToggle(gRegion, admFly,       cfgBool("fly", false))
  setToggle(gRegion, admTeleport,  cfgBool("teleport", false))
  setToggle(gRegion, admTimeOfDay, cfgBool("timeOfDay", false))
  cfgEspMaxDistance = setting("espMaxDistance").asFloat(400.0)

# ---------------------------------------------------------------------------
# The F12 settings schema (client-only route; the F6 menu is the live control)
# ---------------------------------------------------------------------------

proc adminSchema(): seq[Setting] =
  result = @[
    boolSetting("esp", "ESP", true, category = "Visuals",
                description = "Boxes and side-colour on every player (F6 menu)"),
    boolSetting("godmode", "God mode", true, category = "Combat",
                description = "Pin the local player's health (F6 menu)"),
    boolSetting("infiniteStamina", "Infinite stamina", false, category = "Movement"),
    boolSetting("noRecoil", "No recoil / sway", false, category = "Combat",
                implemented = false, description = "Read; write not bound yet"),
    boolSetting("noWeight", "No weight", false, category = "Movement",
                implemented = false, description = "Read; write not bound yet"),
    boolSetting("instantHeal", "Instant heal", false, category = "Combat",
                implemented = false, description = "Read; write not bound yet"),
    boolSetting("unlimitedAmmo", "Unlimited ammo", false, category = "Combat",
                implemented = false, description = "Read; write not bound yet"),
    boolSetting("thermalVision", "Thermal vision", false, category = "Visuals",
                implemented = false, description = "Read; write not bound yet"),
    boolSetting("nightVision", "Night vision", false, category = "Visuals",
                implemented = false, description = "Read; write not bound yet"),
    boolSetting("fly", "Fly / noclip", false, category = "Movement",
                implemented = false, description = "Read; write not bound yet"),
    boolSetting("teleport", "Teleport to marker", false, category = "Movement",
                implemented = false, description = "Read; write not bound yet"),
    boolSetting("timeOfDay", "Set time of day", false, category = "World",
                implemented = false, description = "Read; write not bound yet"),
    floatSetting("espMaxDistance", "ESP max distance (m)", 400.0,
                 lo = 10.0, hi = 2000.0, step = 10.0, category = "Visuals")]

proc onAdminSettings(url, body, session: string): string =
  if body.len > 0 and applySettingFromBody(body) == Ok:
    applyConfigToggles()
  result = declaredSchemaJson().text

proc onAdminSettingsReset(url, body, session: string): string =
  if resetFromBody(body) == Ok:
    applyConfigToggles()
  result = declaredSchemaJson().text

# ---------------------------------------------------------------------------
# Capability -- what the mod could actually arm, so the menu is honest
# ---------------------------------------------------------------------------

proc publishCapability() =
  var cap = 0'u32
  if dataResolved():  cap = cap or (1'u32 shl admEsp)
  if godCapable():    cap = cap or (1'u32 shl admGodmode)
  if staminaCapable(): cap = cap or (1'u32 shl admStamina)
  # Every other mode is not bound on this build; left 0 => drawn "unavailable".
  setCapability(gRegion, cap)

# ---------------------------------------------------------------------------
# The per-frame pass, on the host thread (memory reads need no Unity thread)
# ---------------------------------------------------------------------------

var gTick = 0'i64
var gReported = false

proc onUpdate(elapsedMs: int64): Status =
  if gRegion == nil:
    return Ok
  gTick = gTick + 1
  discard dataOpen()

  # Screen size the overlay is drawing at, so projection matches the boxes.
  var w = hudWidth(gRegion)
  var h = hudHeight(gRegion)
  if w <= 0: w = 1920
  if h <= 0: h = 1080

  collectAndPublish(gRegion, cfgEspMaxDistance, w, h)

  # God mode patches live combat code, so it is DEFERRED: applied only in an
  # actual raid (a live GameWorld), never at boot or the menu -- patching a
  # damage function while the client is still settling is both pointless and the
  # prime suspect for the boot crash. Outside a raid the patch is held reverted.
  # (The byte-patch itself also byte-verifies the exact prologue before writing,
  # so even a wrong RVA on a future build refuses rather than corrupts.)
  if dataInRaid():
    setGodmode(toggleOn(gRegion, admGodmode))
    if toggleOn(gRegion, admStamina): applyStamina()
  else:
    setGodmode(false)

  publishCapability()
  setStatus(gRegion, dataStatus() & "  " & godStatus())

  if not gReported and gTick > 200:
    gReported = true
    info "admin: " & dataStatus()
  result = Ok

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  gRegion = adminMap()
  if gRegion == nil:
    warn ModName & ": could not map the shared HUD region; the menu and ESP " &
         "are unavailable this session (the game is otherwise untouched)"
    declareSettings(adminSchema())
    return Ok

  applyConfigToggles()
  declareSettings(adminSchema())
  discard serve("/aowlspt/settings/" & ModGuid, onAdminSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onAdminSettingsReset)

  if side() == sideClient:
    info ModName & " " & ModVersion &
         " loaded; F6 opens the admin menu (ESP + God mode on by default). " &
         "Cheats resolve by field offset -- see adminDiag() for what bound."
  else:
    info ModName & " loaded on a non-client side; the HUD does nothing here"
  result = Ok

proc onUnload(): Status =
  ## Revert the God mode patch so unloading the mod restores the game's own
  ## damage code. The shared region is a file mapping shared with the overlay; it
  ## is left mapped (the overlay may still be drawing).
  setGodmode(false)
  result = Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
