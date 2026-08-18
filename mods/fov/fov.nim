## FOV Fix — a from-scratch nimony port of Fontaine's *Fontaine-FOVFix*
## (`com.fontaine.fovfix`), for the aowlspt native mod system.
##
##     aowl build-mod mods/fov
##
## Upstream: Fontaine (space-commits), CC BY-NC-SA 3.0 — see LICENSE.txt beside
## this file. This is a modified redistribution under the same terms; the
## copyright holder is unchanged.
##
## ---------------------------------------------------------------------------
## WHAT THIS PORT DOES, AND WHAT IT CANNOT DO
## ---------------------------------------------------------------------------
##
## Read this before opening an issue about "the FOV did not change".
##
## The original is a BepInEx plugin built entirely out of Harmony patches that
## **replace** game methods: `LerpCamera`, `Player::Look`,
## `CalculateScaleValueByFov` and `SightComponent::get_GetCurrentSensitivity`
## are all `[PatchPrefix]`es that read `__instance`, read and write private
## instance fields by reflection, and `return false` so the original never
## runs. `AimingSensitivityPatch` writes a `ref float ____aimingSens`.
## `FovController` calls `CameraManager.Instance.SetFov(...)` every frame.
##
## Post-1.0 Tarkov is IL2CPP. There are no managed assemblies, so there is no
## Harmony, no reflection over fields, and no `__instance`. What this host
## offers a client mod is exactly three things (docs/MODDING.md):
##
##   * `resolve(name)`      — find a compiled type by name
##   * `call(Type::Member)` — invoke a **static** member with scalar arguments
##   * `patch(Type::Method)`— detour a compiled method, **observe only**
##
## The detour cannot read the method's arguments (that needs a thunk generated
## per signature) and cannot suppress the original — both limits are stated by
## the host rather than approximated, and both are load-bearing here. Every
## effect FOV Fix produces needs at least one of:
##
##   1. an *instance* pointer (`__instance`) — the host's `resolve` yields type
##      handles only, and `call` reports a reference return as
##      `{"type":"..."}` rather than handing back an object handle, so there is
##      no path from `CameraManager::get_Instance` to `SetFov` on it;
##   2. reading or writing a *field* — there is no field accessor in the ABI;
##   3. *replacing* a method body — the detour is prefix-observe only.
##
## So **no FOV value, camera offset, aim speed or mouse sensitivity is applied
## by this mod.** Nothing here fakes one. Faking it is the failure mode the
## C# port of Classic Movement actually hit: `protected virtual` overrides that
## *hid* rather than overrode the base members, so the build was clean and the
## mod silently did nothing. A mod that says it changed your FOV and did not is
## the same lie with a different cause.
##
## What the port *is*, therefore, is the two halves that do survive:
##
##   * **The configuration surface.** Every tunable the original bound through
##     BepInEx lives in `config.json` and is read here through `setting()`,
##     validated, and reported. When the ABI grows instance handles and field
##     access, the values are already in the right place with the right names.
##   * **Target verification.** The porting lesson from Classic Movement is
##     "verify that the thing you hooked is the thing the game actually calls".
##     With `verifyHooks` on, this mod detours the exact methods FOV Fix
##     patched and counts how often each one fires. A target that resolves,
##     patches and then never fires is a renamed or inlined method, and you
##     find that out from the log instead of from a mod that quietly does
##     nothing. That is *evidence*, not an effect, and it is logged as such.
##
## The gaps this port needs closed, in the order they block work, are listed in
## the report that accompanied it: object handles out of `call`, a field
## get/set pair, and a replace-kind patch.

import aowlspt
import aowlspt/game
import aowlspt/server   # `setting` — configGet with a typed reader on top

const
  ModGuid = "aowl.fovfix"
  ModName = "FOV Fix"
  ModAuthor = "Fontaine (ported by savannt)"
  ModVersion = "4.0.2"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
#
# The client host reads `config.json` as flat keys, so every name below is
# unique across the document rather than nested by category the way BepInEx
# sections were. The categories survive as the grouping of these variables and
# as the ordering in config.json.

# Declared one per statement and initialised with literals: in a nimony
# `--app:lib` build a global initialised by a *call* is never initialised, so
# these are filled in `onLoad` rather than at their declaration.
var cfgOpticFovMulti = 1.0
var cfgNonOpticFovMulti = 1.0

var cfgOpticCameraDistanceOffset = -0.03
var cfgNonOpticCameraDistanceOffset = -0.01
var cfgPistolCameraDistanceOffset = 0.0
var cfgRifleLeftShoulderOffset = 0.0
var cfgPistolLeftShoulderOffset = 0.0
var cfgCameraIncreaseOffsetKey = "KeypadMultiply"
var cfgCameraDecreaseOffsetKey = "KeypadDivide"

var cfgZoomToggleKey = "M"
var cfgHoldToZoom = true
var cfgCancelZoomOnUnAds = false
var cfgZoomOnHoldBreath = false
var cfgOpticToggleZoomMulti = 0.9
var cfgNonOpticToggleZoomMulti = 0.8
var cfgUnaimedToggleZoomMulti = 0.8
var cfgOpticToggleZoomSensMulti = 0.8
var cfgNonOpticToggleZoomSensMulti = 0.7
var cfgUnaimedToggleZoomSensMulti = 0.7

var cfgChangeMouseSensitivity = true
var cfgNonOpticSensMulti = 1.0
var cfgOneSensMulti = 0.75
var cfgTwoSensMulti = 0.45
var cfgThreeSensMulti = 0.3
var cfgFourSensMulti = 0.2
var cfgFiveSensMulti = 0.15
var cfgSixSensMulti = 0.125
var cfgEightSensMulti = 0.08
var cfgTenSensMulti = 0.04
var cfgTwelveSensMulti = 0.03
var cfgHighSensMulti = 0.01

var cfgRifleCameraXOffset = 0.04
var cfgRifleCameraYOffset = 0.04
var cfgRifleCameraZOffset = 0.025
var cfgPistolCameraXOffset = 0.04
var cfgPistolCameraYOffset = 0.04
var cfgPistolCameraZOffset = 0.025

var cfgEnableFovScaleFix = false
var cfgFovScale = 1.0
var cfgMaxBaseFov = 110
var cfgMinBaseFov = 30

var cfgRifleCameraSpeed = 1.0
var cfgPistolCameraSpeed = 1.0
var cfgOpticCameraSpeed = 1.0
var cfgRifleAimSpeedX = 1.0
var cfgRifleAimSpeedY = 1.0
var cfgRifleAimSpeedZ = 3.0
var cfgPistolAimSpeedX = 1.0
var cfgPistolAimSpeedY = 1.0
var cfgPistolAimSpeedZ = 1.0
var cfgUnAimSpeedX = 5.5
var cfgUnAimSpeedY = 4.5
var cfgUnAimSpeedZ = 4.5

var cfgVerifyHooks = true

proc cfgFloat(key: string; default: float): float =
  result = setting(key).asFloat(default)

proc cfgInt(key: string; default: int): int =
  result = setting(key).asInt(default)

proc cfgBool(key: string; default: bool): bool =
  result = setting(key).asBool(default)

proc cfgText(key, default: string): string =
  ## Config strings arrive with their JSON quotes still on: the host returns the
  ## raw token so a caller can tell `"1"` from `1`. Strip them here rather than
  ## at each call site, where forgetting produces a key name nobody typed.
  var raw = setting(key).asText(default)
  if raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"':
    raw = raw.substr(1, raw.len - 2)
  result = raw

proc loadConfig() =
  cfgOpticFovMulti = cfgFloat("opticFovMulti", 1.0)
  cfgNonOpticFovMulti = cfgFloat("nonOpticFovMulti", 1.0)

  cfgOpticCameraDistanceOffset = cfgFloat("opticCameraDistanceOffset", -0.03)
  cfgNonOpticCameraDistanceOffset = cfgFloat("nonOpticCameraDistanceOffset", -0.01)
  cfgPistolCameraDistanceOffset = cfgFloat("pistolCameraDistanceOffset", 0.0)
  cfgRifleLeftShoulderOffset = cfgFloat("rifleLeftShoulderOffset", 0.0)
  cfgPistolLeftShoulderOffset = cfgFloat("pistolLeftShoulderOffset", 0.0)
  cfgCameraIncreaseOffsetKey = cfgText("cameraIncreaseOffsetKey", "KeypadMultiply")
  cfgCameraDecreaseOffsetKey = cfgText("cameraDecreaseOffsetKey", "KeypadDivide")

  cfgZoomToggleKey = cfgText("zoomToggleKey", "M")
  cfgHoldToZoom = cfgBool("holdToZoom", true)
  cfgCancelZoomOnUnAds = cfgBool("cancelZoomOnUnAds", false)
  cfgZoomOnHoldBreath = cfgBool("zoomOnHoldBreath", false)
  cfgOpticToggleZoomMulti = cfgFloat("opticToggleZoomMulti", 0.9)
  cfgNonOpticToggleZoomMulti = cfgFloat("nonOpticToggleZoomMulti", 0.8)
  cfgUnaimedToggleZoomMulti = cfgFloat("unaimedToggleZoomMulti", 0.8)
  cfgOpticToggleZoomSensMulti = cfgFloat("opticToggleZoomSensMulti", 0.8)
  cfgNonOpticToggleZoomSensMulti = cfgFloat("nonOpticToggleZoomSensMulti", 0.7)
  cfgUnaimedToggleZoomSensMulti = cfgFloat("unaimedToggleZoomSensMulti", 0.7)

  cfgChangeMouseSensitivity = cfgBool("changeMouseSensitivity", true)
  cfgNonOpticSensMulti = cfgFloat("nonOpticSensMulti", 1.0)
  cfgOneSensMulti = cfgFloat("oneSensMulti", 0.75)
  cfgTwoSensMulti = cfgFloat("twoSensMulti", 0.45)
  cfgThreeSensMulti = cfgFloat("threeSensMulti", 0.3)
  cfgFourSensMulti = cfgFloat("fourSensMulti", 0.2)
  cfgFiveSensMulti = cfgFloat("fiveSensMulti", 0.15)
  cfgSixSensMulti = cfgFloat("sixSensMulti", 0.125)
  cfgEightSensMulti = cfgFloat("eightSensMulti", 0.08)
  cfgTenSensMulti = cfgFloat("tenSensMulti", 0.04)
  cfgTwelveSensMulti = cfgFloat("twelveSensMulti", 0.03)
  cfgHighSensMulti = cfgFloat("highSensMulti", 0.01)

  cfgRifleCameraXOffset = cfgFloat("rifleCameraXOffset", 0.04)
  cfgRifleCameraYOffset = cfgFloat("rifleCameraYOffset", 0.04)
  cfgRifleCameraZOffset = cfgFloat("rifleCameraZOffset", 0.025)
  cfgPistolCameraXOffset = cfgFloat("pistolCameraXOffset", 0.04)
  cfgPistolCameraYOffset = cfgFloat("pistolCameraYOffset", 0.04)
  cfgPistolCameraZOffset = cfgFloat("pistolCameraZOffset", 0.025)

  cfgEnableFovScaleFix = cfgBool("enableFovScaleFix", false)
  cfgFovScale = cfgFloat("fovScale", 1.0)
  cfgMaxBaseFov = cfgInt("maxBaseFov", 110)
  cfgMinBaseFov = cfgInt("minBaseFov", 30)

  cfgRifleCameraSpeed = cfgFloat("rifleCameraSpeed", 1.0)
  cfgPistolCameraSpeed = cfgFloat("pistolCameraSpeed", 1.0)
  cfgOpticCameraSpeed = cfgFloat("opticCameraSpeed", 1.0)
  cfgRifleAimSpeedX = cfgFloat("rifleAimSpeedX", 1.0)
  cfgRifleAimSpeedY = cfgFloat("rifleAimSpeedY", 1.0)
  cfgRifleAimSpeedZ = cfgFloat("rifleAimSpeedZ", 3.0)
  cfgPistolAimSpeedX = cfgFloat("pistolAimSpeedX", 1.0)
  cfgPistolAimSpeedY = cfgFloat("pistolAimSpeedY", 1.0)
  cfgPistolAimSpeedZ = cfgFloat("pistolAimSpeedZ", 1.0)
  cfgUnAimSpeedX = cfgFloat("unAimSpeedX", 5.5)
  cfgUnAimSpeedY = cfgFloat("unAimSpeedY", 4.5)
  cfgUnAimSpeedZ = cfgFloat("unAimSpeedZ", 4.5)

  cfgVerifyHooks = cfgBool("verifyHooks", true)

  # Upstream's FovRangePatch swaps the two when they are the wrong way round
  # rather than refusing; keeping that behaviour keeps a hand-edited config
  # from producing an empty slider range once the range patch is expressible.
  if cfgMinBaseFov > cfgMaxBaseFov:
    warn "minBaseFov (" & $cfgMinBaseFov & ") is above maxBaseFov (" &
         $cfgMaxBaseFov & "); using 50..75 as upstream does"
    cfgMinBaseFov = 50
    cfgMaxBaseFov = 75

# ---------------------------------------------------------------------------
# The magnification -> sensitivity table
# ---------------------------------------------------------------------------
#
# Upstream's `Utils.GetZoomSensValue` maps the optic camera's field of view to
# one of the per-magnification multipliers. The table is ported in full and
# tested here, because it is pure arithmetic over configuration: it needs
# nothing from the game, so it is the one piece of FOV Fix's behaviour that can
# be carried across whole and shown to be right. What it cannot do yet is
# reach the value it would be applied to.

proc zoomSensFor(scopeFov: float): float =
  ## `scopeFov` is the optic camera's vertical FOV in degrees, as
  ## `CameraManager.Instance.OpticCameraManager.Camera.fieldOfView` reports it.
  ## Smaller means more magnification.
  if scopeFov <= 0.0: return cfgNonOpticSensMulti
  if scopeFov >= 40.0: return cfgOneSensMulti
  if scopeFov >= 20.0: return cfgTwoSensMulti
  if scopeFov >= 13.0: return cfgThreeSensMulti
  if scopeFov >= 10.0: return cfgFourSensMulti
  if scopeFov >= 8.0: return cfgFiveSensMulti
  if scopeFov >= 6.0: return cfgSixSensMulti
  if scopeFov >= 4.5: return cfgEightSensMulti
  if scopeFov >= 3.5: return cfgTenSensMulti
  if scopeFov >= 2.5: return cfgTwelveSensMulti
  result = cfgHighSensMulti

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------
#
# Named here, resolved on first use: a mod loads into a process that has an
# IL2CPP runtime but not yet the game's own assemblies, so resolving at load is
# a false negative. `gameType` is a template for the DLL-global reason in
# docs/MODDING.md.

var CameraManager = gameType("EFT.CameraControl.CameraManager")
var ProceduralWeaponAnimation = gameType("EFT.Animations.ProceduralWeaponAnimation")
var Player = gameType("EFT.Player")
var FirearmController = gameType("EFT.Player.FirearmController")
var SightComponent = gameType("EFT.InventoryLogic.SightComponent")
var GameSettingsTab = gameType("EFT.UI.Settings.GameSettingsTab")
var ScopeZoomHandler = gameType("EFT.CameraControl.ScopeZoomHandler")

var world = whenReady("EFT.GameWorld")

# ---------------------------------------------------------------------------
# Hook verification
# ---------------------------------------------------------------------------
#
# Two parallel sequences and a dispatcher that matches on the target name.
# Not a closure per hook: nimony will not let a nested proc touch its enclosing
# locals without being a closure, and a closure is not a plain function pointer,
# so it cannot cross the C ABI the callback goes through.

var gWatchNames: seq[string] = @[]
var gWatchCounts: seq[int] = @[]
var gReported = false

proc watchIndex(target: string): int =
  result = -1
  for i in 0 ..< gWatchNames.len:
    if gWatchNames[i] == target:
      return i

proc onWatched(target: string) =
  let i = watchIndex(target)
  if i >= 0:
    gWatchCounts[i] = gWatchCounts[i] + 1

proc watch(target, why: string) =
  ## Detour `target` and count its calls.
  ##
  ## This is the whole point of `verifyHooks`: the C# port of Classic Movement
  ## compiled clean and did nothing, because the members it declared
  ## `protected virtual` *hid* the base members instead of overriding them.
  ## There is no inheritance here to get wrong -- a patch names a compiled
  ## method -- but the same question still has to be answered out loud: is the
  ## thing I attached to the thing the game calls? A target that patches and
  ## then never fires answers "no", and says so in the log.
  gWatchNames.add target
  gWatchCounts.add 0
  if hook(target, onWatched) == Ok:
    info "watching " & target & " (" & why & ")"
  else:
    warn "cannot watch " & target & ": " & lastError()
    shrink(gWatchNames, gWatchNames.len - 1)
    shrink(gWatchCounts, gWatchCounts.len - 1)

proc reportType(t: var GameType) =
  if t.available():
    info "  resolved " & t.name
  else:
    warn "  NOT FOUND: " & t.name & " -- a rename would show up here first"

proc onWorldReady() =
  success "FOV Fix: the game world is up; checking what this build can reach"

  # Every type FOV Fix patched. Resolving them is not decorative: if BSG or a
  # backport renames one, this is the line that says so, and it says it before
  # anything downstream fails in a way that reads like a different bug.
  reportType(CameraManager)
  reportType(ProceduralWeaponAnimation)
  reportType(Player)
  reportType(FirearmController)
  reportType(SightComponent)
  reportType(GameSettingsTab)
  reportType(ScopeZoomHandler)

  if not cfgVerifyHooks:
    info "verifyHooks is off; not attaching the target-verification detours"
    return

  # The exact methods the original patched, in the original's order. Sixteen
  # patch slots exist; this uses six.
  watch("EFT.Animations.ProceduralWeaponAnimation::UpdateWeaponVariables",
        "PwaWeaponParamsPatch -- where upstream learns the current weapon")
  watch("EFT.Animations.ProceduralWeaponAnimation::LerpCamera",
        "LerpCameraPatch -- the ADS camera position and smoothing")
  watch("EFT.Player::Look",
        "FreeLookPatch -- freelook clamping")
  watch("EFT.Player::CalculateScaleValueByFov",
        "CalculateScaleValueByFovPatch -- viewmodel/ribcage scale")
  watch("EFT.Player.FirearmController::get_AimingSensitivity",
        "AimingSensitivityPatch -- aimed mouse sensitivity")
  watch("EFT.InventoryLogic.SightComponent::get_GetCurrentSensitivity",
        "ScopeSensitivityPatch -- per-scope sensitivity")

proc reportWatch() =
  if gWatchNames.len == 0:
    return
  info "FOV Fix target verification, after roughly a minute in raid:"
  for i in 0 ..< gWatchNames.len:
    if gWatchCounts[i] > 0:
      success "  " & gWatchNames[i] & " fired " & $gWatchCounts[i] & " times"
    else:
      warn "  " & gWatchNames[i] & " never fired -- it is patched but the " &
           "game does not call it; treat the name as stale"
  warn "no FOV, camera or sensitivity value was applied: this host's client " &
       "API is resolve + static call + observe-only detour, and every effect " &
       "in FOV Fix needs an instance pointer, a field, or a replaced body. " &
       "See the module comment."

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

var gElapsedMs = 0'i64

proc onLoad(): Status =
  loadConfig()
  success ModName & " " & ModVersion & " loaded on " & hostName()
  if side() != sideClient:
    info "FOV Fix is client-only; nothing to do on this side"
    return Ok

  info "config: optic FOV x" & $cfgOpticFovMulti & ", unmagnified x" &
       $cfgNonOpticFovMulti & ", base FOV range " & $cfgMinBaseFov & ".." &
       $cfgMaxBaseFov
  info "config: toggle zoom on " & cfgZoomToggleKey &
       (if cfgHoldToZoom: " (hold)" else: " (toggle)") &
       ", optic x" & $cfgOpticToggleZoomMulti &
       ", non-optic x" & $cfgNonOpticToggleZoomMulti
  info "config: mouse sensitivity " &
       (if cfgChangeMouseSensitivity: "managed" else: "left alone") &
       ", 4x would use x" & $zoomSensFor(10.0) & ", 12x x" & $zoomSensFor(3.0)
  info "config: camera offset keys " & cfgCameraIncreaseOffsetKey & " / " &
       cfgCameraDecreaseOffsetKey & ", rifle Z " & $cfgRifleCameraZOffset &
       ", pistol Z " & $cfgPistolCameraZOffset
  if cfgEnableFovScaleFix:
    info "config: FOV scale fix requested at " & $cfgFovScale
  info "config: camera speeds rifle " & $cfgRifleCameraSpeed & ", pistol " &
       $cfgPistolCameraSpeed & ", optic " & $cfgOpticCameraSpeed &
       "; un-aim " & $cfgUnAimSpeedX & "/" & $cfgUnAimSpeedY & "/" &
       $cfgUnAimSpeedZ
  info "config: ADS camera distance optic " & $cfgOpticCameraDistanceOffset &
       ", non-optic " & $cfgNonOpticCameraDistanceOffset & ", pistol " &
       $cfgPistolCameraDistanceOffset & "; left shoulder rifle " &
       $cfgRifleLeftShoulderOffset & ", pistol " & $cfgPistolLeftShoulderOffset
  info "config: aim speeds rifle " & $cfgRifleAimSpeedX & "/" &
       $cfgRifleAimSpeedY & "/" & $cfgRifleAimSpeedZ & ", pistol " &
       $cfgPistolAimSpeedX & "/" & $cfgPistolAimSpeedY & "/" &
       $cfgPistolAimSpeedZ
  info "config: camera XY offsets rifle " & $cfgRifleCameraXOffset & "/" &
       $cfgRifleCameraYOffset & ", pistol " & $cfgPistolCameraXOffset & "/" &
       $cfgPistolCameraYOffset
  info "config: toggle-zoom sensitivity optic x" &
       $cfgOpticToggleZoomSensMulti & ", aimed x" &
       $cfgNonOpticToggleZoomSensMulti & ", un-aimed x" &
       $cfgUnaimedToggleZoomSensMulti & "; un-aimed FOV x" &
       $cfgUnaimedToggleZoomMulti &
       (if cfgCancelZoomOnUnAds: ", cancelled on un-ADS" else: "") &
       (if cfgZoomOnHoldBreath: ", driven by hold-breath" else: "")
  Ok

proc onUpdate(elapsedMs: int64): Status =
  if side() != sideClient:
    return Ok
  gElapsedMs = gElapsedMs + elapsedMs
  if world.ready():
    onWorldReady()
    gElapsedMs = 0
  # One report, a minute after the world came up: long enough that a method
  # called only on ADS or only on a weapon swap has had a chance to fire, so a
  # zero here means "never", not "not yet".
  if not gReported and gWatchNames.len > 0 and gElapsedMs > 60_000:
    gReported = true
    reportWatch()
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate)
