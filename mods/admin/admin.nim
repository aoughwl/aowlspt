## Admin / cheat menu -- a fully native, client-side admin panel for post-1.0
## Escape From Tarkov (IL2CPP build 1.1.0.1.46777).
##
## ---------------------------------------------------------------------------
## THE ARCHITECTURE, AND WHY IT IS THIS ONE
## ---------------------------------------------------------------------------
##
## Press **F6** for an in-game admin menu of togglable cheat modes. **Every mode
## defaults OFF** -- this build goes to testers, so nothing cheats until the
## player opts in (config.json, the F12 schema and `AOWL_ADM_DEFAULTS` are three
## copies of that one decision and must agree).
##
## Calling a managed game method through the per-frame `MethodInfo.methodPointer`
## is not available on this build -- the anti-cheat strips it. Three things do
## work, and this mod is built entirely on them:
##
##   * **Reading/writing object memory by a MEASURED STATIC field offset.** No
##     reflection: `il2cpp_object_get_class` and friends FAULT on this build, and
##     every offset in `adm/data.nim` is a constant taken offline from
##     `Il2CppMetadataRegistration.fieldOffsets`. Works from any thread. That is
##     the ESP data pass and the God mode / stamina writes.
##
##   * **A direct call at a byte-verified static RVA.** Direct RVA calls DO work
##     -- only reflection is dead. That is how world->screen projection is
##     obtained: `Camera::get_main` plus the two sret `Matrix4x4` getters, from
##     Unity's own thread via `everyMain`, published as one view-projection
##     matrix that the off-thread ESP pass then does pure arithmetic against.
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
##   * **The offsets and RVAs are MEASURED CONSTANTS for build 1.1.0.1.46777**,
##     not runtime name lookups -- runtime lookup needed the faulting reflection
##     API. A Tarkov update therefore invalidates them, which is exactly why
##     every hop is validated and `adminDiag()` names the FIRST one that did not.
##
##   * **The one remaining external dependency is the GameWorld.** `EFT.GameWorld`
##     is only reachable through `Comfort.Common.Singleton<GameWorld>._instance`,
##     a static on a GENERIC INSTANTIATION whose storage is allocated at runtime
##     and has no static address, so this mod borrows the host's existing
##     read-only `RegisterPlayer` detour cache instead of binding a second detour
##     on the same function (which would overwrite the first's trampoline). That
##     cache is only populated when the host flag `debugEsp` or `botDiag` is on.
##     Not being able to see a world for that reason is INCONCLUSIVE and is
##     reported in those words -- never as "not in a raid".
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
  # EVERY cheat defaults OFF -- this build goes to testers. These fallbacks, the
  # schema below and AOWL_ADM_DEFAULTS in aowlspt_admin.h are three independent
  # copies of the same decision; they must agree, or the effective default is
  # whichever one happened to run last.
  setToggle(gRegion, admEsp,       cfgBool("esp", false))
  setToggle(gRegion, admGodmode,   cfgBool("godmode", false))
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
    boolSetting("esp", "ESP", false, category = "Visuals",
                description = "Boxes and side-colour on every player (F6 menu). " &
                              "Needs the host's GameWorld cache: turn on the " &
                              "debugEsp or botDiag host flag, or adminDiag() " &
                              "reports ESP unavailable."),
    boolSetting("godmode", "God mode", false, category = "Combat",
                description = "Neuters EFT.Player::ApplyDamageInfo while in a " &
                              "raid. GLOBAL: bots stop taking damage too."),
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
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
    if st == Ok: applyConfigToggles()
  result = declaredSchemaReply(st).text

proc onAdminSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  if st == Ok: applyConfigToggles()
  result = declaredSchemaReply(st).text

proc onSettingsHotApply(key: string) =
  ## admin is client-side, so its `/aowlspt/settings/<guid>` route is
  ## registered into nothing and the two handlers above never run in the
  ## client. Without this the F12 edit persists to config.json and the shared
  ## HUD region keeps the OLD toggle until the next launch -- a cheat switch
  ## that flips and changes nothing. Same call the route handler makes, so
  ## there is ONE apply path and not two.
  discard key
  applyConfigToggles()

# ---------------------------------------------------------------------------
# The Unity-thread sampler: the ONLY thing in this mod that calls game code
# ---------------------------------------------------------------------------
#
# `camSample()` calls `Camera::get_main` and the two sret `Matrix4x4` getters.
# Those are Unity calls and are legal only on Unity's own thread; `onUpdate`
# runs on the HOST's thread, which is why the sampler cannot live there.
#
# FACT #136, and the whole reason for the gate below: a client mod that arms
# IL2CPP work before the host's main-thread drain is live kills the client
# about 1.2s in, with `Unity thread live` never confirmed and no client log
# directory to explain it. `mods/fov` hit exactly this and fixed it by asking
# the host, so admin asks the host too. NOT ARMING IS THE DEFAULT: the driver
# stays unarmed, and says why, until the host reports the drain has FIRED.

type MainThread = object
  ok: bool          ## the host answered at all
  bound: bool       ## the drain is on Unity's thread and has already fired
  methodName: string
  frames: int64

proc askMainThread(): MainThread =
  ## `call("aowlspt.host::main_thread")`, decoded. The host answers this before
  ## it checks whether the runtime is up, so it is meaningful with no game --
  ## which is what makes it usable as a gate rather than a race.
  result = MainThread(ok: false, bound: false, methodName: "", frames: 0'i64)
  var raw = ""
  let empty = "[]"
  if call("aowlspt.host::main_thread", empty, raw) != Ok: return
  if raw.len == 0: return
  result.ok = true
  result.bound = asBool(field(raw, "bound"), false)
  result.methodName = asText(field(raw, "method"), "")
  result.frames = int64(asInt(field(raw, "frames"), 0))

var gSamplerState = "not attempted"
var gSamplerArmed = false
var gSamplerFirings = 0
var gSamplerGood = 0

proc onCamTick(payload: string): string =
  ## One firing per host drain, i.e. once per frame, on Unity's thread. It does
  ## exactly one thing -- refresh the view-projection snapshot -- and writes no
  ## game memory. `camSample` byte-verifies all three prologues before its first
  ## call and self-disables after repeated refusals, so this cannot become a
  ## per-frame fault for the rest of the session.
  ## FLAG-GATED, DEFAULT OFF (host rule 5): with the ESP toggle off this calls
  ## nothing at all. The driver stays installed rather than being unbound and
  ## rebound, because binding is the risky operation and toggling is not.
  result = ""
  if gRegion == nil or not toggleOn(gRegion, admEsp): return
  gSamplerFirings = gSamplerFirings + 1
  if camSample(): gSamplerGood = gSamplerGood + 1

proc armCamSampler() =
  ## Idempotent, retried from onUpdate until it arms or refuses for a reason
  ## that cannot change. Never arms optimistically.
  if gSamplerArmed: return
  if camState() == 2:
    gSamplerState = "refused: " & camStateText()
    return
  let mt = askMainThread()
  if not mt.ok:
    gSamplerState = "waiting: this host does not answer " &
                    "aowlspt.host::main_thread, so there is no thread the " &
                    "sampler could be shown to reach"
    return
  if not mt.bound:
    gSamplerState = "waiting: the host's main-thread drain is not confirmed " &
                    "on Unity's thread yet (" &
                    (if mt.methodName.len > 0:
                       "drain " & mt.methodName & ", " & $mt.frames & " firings"
                     else: "no drain method bound") &
                    ") -- arming il2cpp work before it is live crashes the " &
                    "client (fact #136)"
    return
  if everyMain(onCamTick) == Ok:
    gSamplerArmed = true
    gSamplerState = "armed on everyMain, drained from " & mt.methodName &
                    " on Unity's thread"
  else:
    gSamplerState = "refused: everyMain was refused by the host (" &
                    lastError() & "), so world->screen cannot be sampled"

proc samplerDiag(): string =
  "  esp sampler  : " &
  (if gSamplerArmed and gSamplerGood > 0:
     "PASS  " & gSamplerState & "; " & $gSamplerGood & " good samples of " &
     $gSamplerFirings & " firings"
   elif gSamplerArmed and gRegion != nil and not toggleOn(gRegion, admEsp):
     "INCONCLUSIVE  " & gSamplerState & ", but the ESP toggle is OFF so it " &
     "samples nothing -- turn ESP on in the F6 menu"
   elif gSamplerArmed:
     "INCONCLUSIVE  " & gSamplerState & ", " & $gSamplerFirings &
     " firings but NO good sample yet -- " & camStateText()
   else:
     "FAIL  " & gSamplerState) & "\n"

# ---------------------------------------------------------------------------
# Capability -- what the mod could actually arm, so the menu is honest
# ---------------------------------------------------------------------------

proc adminDiag*(): string {.exportc: "aowl_admin_diag", cdecl.} =
  ## What actually bound, and what did not. The load banner has advertised this
  ## since day one but NO SUCH PROC EXISTED -- a diagnostic that is only
  ## promised is worse than none (CLAUDE.md 6).
  ##
  ## Every line is PASS / FAIL / INCONCLUSIVE. "I could not look" -- no raid, no
  ## world, a host flag off -- is INCONCLUSIVE, never a pass and never a FAIL
  ## blamed on the offsets.
  result = "admin diag (" & ModName & " " & ModVersion & ")\n"
  if gRegion == nil:
    result.add "  region       : FAIL  shared HUD region not mapped; " &
               "the F6 menu and ESP are unavailable this session\n"
  else:
    result.add "  region       : PASS  mapped (" & $hudWidth(gRegion) & "x" &
               $hudHeight(gRegion) & " back buffer)\n"
  result.add samplerDiag()
  result.add dataDiag()
  result.add "\n  toggles      : "
  if gRegion == nil:
    result.add "unavailable"
  else:
    var any = false
    for b in 0 ..< int(admCount):
      if toggleOn(gRegion, int32(b)):
        if any: result.add ", "
        result.add modeName(int32(b))
        any = true
    if not any: result.add "all off (the shipped default)"

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
var gRaidReported = false


proc onUpdate(elapsedMs: int64): Status =
  if gRegion == nil:
    return Ok
  gTick = gTick + 1
  discard dataOpen()
  armCamSampler()   # idempotent; waits for the host's Unity-thread drain

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

  # Report once the mod has had time to settle, and AGAIN the first time a raid
  # is actually entered -- the boot report is necessarily INCONCLUSIVE about
  # everything that needs a world, so stopping there would leave the log
  # asserting "no raid" forever.
  if not gReported and gTick > 200:
    gReported = true
    info "admin: " & dataStatus()
  if not gRaidReported and dataInRaid():
    gRaidReported = true
    info adminDiag()
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
    onSettingsApplied(onSettingsHotApply)
    return Ok

  applyConfigToggles()
  declareSettings(adminSchema())
  onSettingsApplied(onSettingsHotApply)
  discard serve("/aowlspt/settings/" & ModGuid, onAdminSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onAdminSettingsReset)

  if side() == sideClient:
    info ModName & " " & ModVersion &
         " loaded; F6 opens the admin menu. ALL cheats default OFF. " &
         "Cheats read measured static field offsets (build 1.1.0.1.46777)."
    info adminDiag()
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
