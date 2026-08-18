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
## WHAT THIS PORT DOES
## ---------------------------------------------------------------------------
##
## The original is a BepInEx plugin: a per-frame `FovController` component plus
## a handful of Harmony prefixes that read `__instance`, rewrite private fields
## and `return false`. Post-1.0 Tarkov is IL2CPP, so none of that exists — but
## the three things those patches needed do now, and this port uses them:
##
##   * **live objects** — a reference return is a handle you can call on;
##   * **fields**, including private ones, read and written by name;
##   * **hooks with arguments and suppression** — `hookArgs` + `stopWith` is a
##     Harmony prefix that returns `false` with a `__result`.
##
## and, for anything on the frame path, **`aowlspt/fast`**: the mod binds a
## method or a field once and then calls it in ~10 ns instead of ~1000. A FOV
## write happens every frame, so it is on that path and nowhere near the boxed
## one (docs/PERF.md).
##
## Three effects are implemented, each one armed only when every binding it
## needs actually resolved, and each one reporting whether it applied:
##
##   1. **The per-frame FOV write.** Upstream's `FovController`: the camera's
##      field of view is multiplied by `opticFovMulti` or `nonOpticFovMulti`
##      while aiming. Entirely on the fast path — `GameWorld.Instance` →
##      `MainPlayer` → `ProceduralWeaponAnimation` → `IsAiming`, and
##      `CameraManager.Instance` → `SetFov` — driven from a cheap hook on a
##      method the game already calls every frame, so the write lands on the
##      game thread rather than the host's own (`invoke_main` is *not* Unity's
##      main thread, docs/MODDING.md).
##   2. **`Player::CalculateScaleValueByFov`.** A float in, a float out, and
##      upstream replaces the body. `hookArgs` + `stopWith` expresses that
##      exactly. Gated on `enableFovScaleFix`.
##   3. **`SightComponent::get_GetCurrentSensitivity`.** A float getter whose
##      body upstream replaces with the magnification→sensitivity table below.
##      Same mechanism; the table is the pure arithmetic it always was, and it
##      is now wired to the optic camera's live field of view.
##
## ---------------------------------------------------------------------------
## WHAT IS STILL NOT EXPRESSIBLE, AND WHY
## ---------------------------------------------------------------------------
##
## Reported here rather than approximated. Every one of these is blocked by a
## specific missing capability, named so it can be fixed rather than guessed
## around.
##
## * **`ProceduralWeaponAnimation::LerpCamera`** — upstream's `LerpCameraPatch`
##   replaces the ADS camera lerp: it reads and writes the instance's `Vector3`
##   camera-offset fields and its per-axis speeds. Two blockers. A hook is not
##   told **which instance** it fired on — `args` carries the declared
##   parameters and not `this` — and a `Vector3` is a 12-byte value type that
##   neither the fast path (it would have to be copied, not loaded) nor the
##   boxed field reader will hand over. Both would have to go.
##
## * **`Player::Look`** — upstream's `FreeLookPatch` clamps the free-look
##   angles on `__instance`. Same missing `this`, and the argument is a
##   `Vector2`: a hook that asked for arguments would have the host classify
##   that struct as a reference and take a GC handle to a register that holds
##   float bits. This port refuses to install an argument hook on any method
##   with a value-type parameter for exactly that reason — see `argsSafe`.
##
## * **`FirearmController::get_AimingSensitivity`** — upstream injects
##   `ref float ____aimingSens`, i.e. the private `_aimingSens` field of the
##   instance, and **scales** it. The interesting half of the question is
##   whether `stopWith` expresses that, and the answer is: *for a getter whose
##   patch sets an absolute value, yes, exactly* — writing the backing field
##   and returning it is indistinguishable from returning it. But upstream does
##   not set an absolute value, it multiplies the one the original would have
##   produced, and a prefix that suppresses the original never learns what that
##   was. Expressing "post-process the result" needs a **postfix** patch whose
##   handler is given the return value; `PatchKind` has `pkPostfix` and the
##   host ignores it (every patch is a prefix detour). Left out.
##
## * **The toggle-zoom key.** `zoomToggleKey`, `holdToZoom` and the three
##   `*ToggleZoomMulti` settings need to know whether a key is down.
##   `UnityEngine.Input::GetKey` takes a `KeyCode`, which is an enum, and
##   mapping the configured names onto its numeric values by hand is precisely
##   the kind of guess this port does not make. The settings are read, reported
##   and carried; nothing acts on them.
##
## * **The base-FOV slider range** (`minBaseFov`/`maxBaseFov`) — upstream's
##   `FovRangePatch` rewrites the slider bounds on a `GameSettingsTab`
##   instance. Missing `this` again.
##
## ---------------------------------------------------------------------------
## HOW YOU KNOW IT WORKED
## ---------------------------------------------------------------------------
##
## The verification machinery that was this port's only content is kept, and
## extended. `verifyHooks` still detours the exact methods upstream patched and
## counts them, because "the thing I hooked is not the thing the game calls" is
## the failure mode that compiles clean and does nothing. On top of that, each
## of the three effects reports its own state — armed, or refused with the
## reason the runtime gave — and its own applied count. A minute into the
## world the log says both: what fired, and what this mod actually did.

import aowlspt
import aowlspt/game
import aowlspt/server   # `setting` — configGet with a typed reader on top
import aowlspt/il2cpp   # the runtime's own C API, for signature checks
import aowlspt/fast     # bind once, call in ~10 ns — docs/PERF.md

const
  ModGuid = "aowl.fovfix"
  ModName = "FOV Fix"
  ModAuthor = "Fontaine (ported by savannt)"
  ModVersion = "4.1.0"

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
# one of the per-magnification multipliers. Pure arithmetic over configuration,
# ported whole; what has changed since the first version of this port is that
# it is now reachable — the optic camera's live field of view goes in one end
# and `SightComponent::get_GetCurrentSensitivity` returns the result.

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

const
  TyGameWorld = "EFT.GameWorld"
  TyPlayer = "EFT.Player"
  TyPwa = "EFT.Animations.ProceduralWeaponAnimation"
  TyCamera = "EFT.CameraControl.CameraManager"
  TyUnityCamera = "UnityEngine.Camera"
  TySight = "EFT.InventoryLogic.SightComponent"

  FrameDriver = "EFT.Player::Look"
    ## The per-frame hook the FOV write rides on.
    ##
    ## It has to be a method the game already calls every frame, because the
    ## alternative — `onUpdate` — runs on the host's own attached thread, and
    ## `invoke_main` queues onto that same thread rather than Unity's. Writing
    ## a camera's field of view from there is not legal. `Look` is upstream's
    ## `FreeLookPatch` target, so it is one this port already watches, and it
    ## is reached once per player per frame.

# ---------------------------------------------------------------------------
# The runtime, and the signature checks that gate every hook
# ---------------------------------------------------------------------------
#
# A mod DLL is in the same process as the host, so `openIl2Cpp` binds the
# already-loaded `GameAssembly.dll` directly and the host is simply not on the
# path (docs/PERF.md). That buys two things: the fast path, and the runtime's
# own metadata — which is what makes it possible to *check* a signature before
# hooking it rather than assuming one.

var rt: Il2Cpp
var rtOpen = false

proc openRuntime(): bool =
  if rtOpen:
    return true
  rt = openIl2Cpp()
  if not rt.loaded:
    return false
  let missing = rt.missingEssential()
  if missing.len > 0:
    warn "the IL2CPP runtime is missing " & $missing.len &
         " essential entry points; the fast path stays off"
    return false
  rtOpen = true
  result = true

proc signatureOf(owner, member: string; argc: int;
                 params: var seq[string]; ret: var string): bool =
  ## The declared parameter types and return type of a method, from the
  ## runtime's own metadata. `argc` of -1 matches any arity, exactly as the
  ## host's `patch` does.
  params = @[]
  ret = ""
  if not rtOpen:
    return false
  let cls = findClass(rt, owner)
  if cls == nil:
    return false
  let m = findMethod(rt, cls, member, argc)
  if m == nil:
    return false
  let n = methodParamCount(rt, m)
  for i in 0 ..< n:
    params.add typeName(rt, methodParam(rt, m, i))
  ret = typeName(rt, methodReturnType(rt, m))
  result = true

proc describeSig(params: seq[string]; ret: string): string =
  result = "("
  for i in 0 ..< params.len:
    if i > 0: result.add ", "
    result.add params[i]
  result.add ") -> " & ret

proc argsSafe(params: seq[string]): bool =
  ## Whether it is safe to ask the host for this method's arguments.
  ##
  ## This is a guard, not a convenience. The host builds the argument array by
  ## the declared type name: primitives and strings it formats, and **anything
  ## else it treats as a reference** — it takes the register, calls
  ## `il2cpp_gc_handle_new` on it and reports a handle. For a `Vector2`, a
  ## `Vector3` or an enum that register holds float bits or a small integer,
  ## not an object pointer, and handing that to the collector is not a wrong
  ## answer, it is a crash in the middle of a game method.
  ##
  ## `classifyType` answers the same question the fast path asks: a primitive
  ## or a reference is a kind, and a value type — struct or enum — is `fkNone`.
  ## So a method with any unclassifiable parameter does not get an argument
  ## hook from this mod, and the log says which type stopped it.
  result = true
  for i in 0 ..< params.len:
    if classifyType(rt, params[i]) == fkNone:
      return false

# ---------------------------------------------------------------------------
# Effects: what this mod applies, and whether it managed to
# ---------------------------------------------------------------------------
#
# Each effect carries a state string — "armed", or "refused: <what the runtime
# said>" — and its own applied counter. Nothing here is a boolean "installed":
# a patch that installs and never runs is the whole reason this mod counts
# anything at all, and the same doubt applies to an effect.

var gFovState = "not attempted"
var gFovWrites = 0
var gScaleState = "not attempted"
var gScaleHits = 0
var gSensState = "not attempted"
var gSensHits = 0

proc armed(state: string): bool =
  ## An effect state reads "armed..." or "refused: ..." or "off (...)". Only
  ## the first means a hook was installed, and that is the question every
  ## caller of this actually has.
  result = state.len >= 5 and state.substr(0, 4) == "armed"

# The FOV chain, bound once. `Binding` and `FieldBinding` are declared bare and
# assigned from a proc: a nimony `--app:lib` global initialised by a *call* is
# silently left zeroed, and a zeroed Binding has `ok = false`, so it fails safe
# but never becomes true. See fast.nim's rule 1.
var bWorld: Binding
var bMainPlayer: Binding
var bPwa: Binding
var bIsAiming: Binding
var bScope: Binding
var bIsOptic: Binding
var bCamInstance: Binding
var bCamCamera: Binding
var bCamFov: Binding
var bSetFov: Binding
var bOpticInstance: Binding
var bOpticCamera: Binding

var gSetFovArgc = 0
var gOpticClassTried = false
var gOpticChainState = "not attempted"
var gBaseFov = 0.0
var gLastFovMs = 0'i64

const
  FovIntervalMs = 4'i64
    ## The FOV write is idempotent and the hook it rides on fires once per
    ## player per frame — including every bot's. Rate-limiting to ~250 Hz means
    ## a raid full of bots costs one write per frame rather than forty, and a
    ## 240 Hz client still gets one per frame.
    ##
    ## The clock is the host's `nowMs` rather than `fast`'s `perfCounter`:
    ## `perfCounter` is an `importc ... nodecl` that only compiles in a
    ## translation unit which `#include`s `abi/aowlspt_fast.h`, and fast.nim
    ## does that emit for itself, not for its importers. A millisecond is the
    ## right resolution for a gate measured in milliseconds anyway.

proc bindFovChain(): bool =
  ## Binds everything the per-frame FOV write needs. All or nothing: an effect
  ## that half-binds is an effect that reads a field it did not check.
  bWorld = bindMethod(rt, TyGameWorld, "get_Instance", 0)
  if not bWorld.ok:
    gFovState = "refused: " & bWorld.why
    return false
  bMainPlayer = bindMethod(rt, TyGameWorld, "get_MainPlayer", 0)
  if not bMainPlayer.ok:
    gFovState = "refused: " & bMainPlayer.why
    return false
  bPwa = bindMethod(rt, TyPlayer, "get_ProceduralWeaponAnimation", 0)
  if not bPwa.ok:
    gFovState = "refused: " & bPwa.why
    return false
  bIsAiming = bindMethod(rt, TyPwa, "get_IsAiming", 0)
  if not bIsAiming.ok:
    gFovState = "refused: " & bIsAiming.why
    return false
  bCamInstance = bindMethod(rt, TyCamera, "get_Instance", 0)
  if not bCamInstance.ok:
    gFovState = "refused: " & bCamInstance.why
    return false
  bCamCamera = bindMethod(rt, TyCamera, "get_Camera", 0)
  if not bCamCamera.ok:
    gFovState = "refused: " & bCamCamera.why
    return false
  bCamFov = bindMethod(rt, TyUnityCamera, "get_fieldOfView", 0)
  if not bCamFov.ok:
    gFovState = "refused: " & bCamFov.why
    return false

  # `SetFov` is the one place upstream's call shape has to be confirmed rather
  # than remembered. Two overloads are accepted, and only if the runtime says
  # the parameters are what this would pass; anything else is refused with the
  # signature printed, which is the line somebody needs in order to fix it.
  var params: seq[string] = @[]
  var ret = ""
  if signatureOf(TyCamera, "SetFov", 3, params, ret) and params.len == 3 and
     params[0] == "System.Single" and params[1] == "System.Single" and
     params[2] == "System.Boolean":
    bSetFov = bindMethod(rt, TyCamera, "SetFov", 3)
    gSetFovArgc = 3
  elif signatureOf(TyCamera, "SetFov", 1, params, ret) and params.len == 1 and
       params[0] == "System.Single":
    bSetFov = bindMethod(rt, TyCamera, "SetFov", 1)
    gSetFovArgc = 1
  else:
    discard signatureOf(TyCamera, "SetFov", -1, params, ret)
    gFovState = "refused: " & TyCamera & "::SetFov is " &
                describeSig(params, ret) &
                ", which is neither (Single, Single, Boolean) nor (Single); " &
                "this port will not guess what the extra parameters mean"
    return false
  if not bSetFov.ok:
    gFovState = "refused: " & bSetFov.why
    return false

  # Optic detection is optional. Without it every aim is treated as
  # unmagnified, which is a *reduced* effect rather than a wrong one, so it
  # does not veto the whole chain -- but it is reported.
  bScope = bindMethod(rt, TyPwa, "get_CurrentScope", 0)
  if not bScope.ok:
    warn "FOV Fix: no optic detection (" & bScope.why &
         "); opticFovMulti will not be used"
  result = true

proc bindOpticIsOptic(scope: Il2CppPtr) =
  ## `CurrentScope`'s declared type is not the type of the object it returns,
  ## and `get_IsOptic` lives on the latter. So the class comes off the object
  ## the first time one exists, and the binding is made against that name.
  if gOpticClassTried:
    return
  gOpticClassTried = true
  let cls = objectClass(rt, scope)
  if cls == nil:
    return
  let owner = fullName(rt, cls)
  if owner.len == 0:
    return
  bIsOptic = bindMethod(rt, owner, "get_IsOptic", 0)
  if bIsOptic.ok:
    info "FOV Fix: optic detection bound on " & owner
  else:
    warn "FOV Fix: " & bIsOptic.why & "; every aim counts as unmagnified"

proc bindOpticCamera(): bool =
  ## The optic camera, for the sensitivity table. Its container was renamed
  ## more than once, so both spellings are tried and the one that resolves is
  ## reported -- an empirical answer rather than a remembered one.
  if bOpticCamera.ok:
    return true
  var owner = "EFT.CameraControl.OpticCameraManagerContainer"
  bOpticInstance = bindMethod(rt, owner, "get_Instance", 0)
  if not bOpticInstance.ok:
    owner = "EFT.CameraControl.OpticCameraManager"
    bOpticInstance = bindMethod(rt, owner, "get_Instance", 0)
  if not bOpticInstance.ok:
    gOpticChainState = "refused: " & bOpticInstance.why
    return false
  bOpticCamera = bindMethod(rt, owner, "get_Camera", 0)
  if not bOpticCamera.ok:
    gOpticChainState = "refused: " & bOpticCamera.why
    return false
  gOpticChainState = "bound on " & owner
  result = true

proc opticFieldOfView(): float =
  ## The optic camera's live vertical FOV, or 0 when there is no optic camera —
  ## which `zoomSensFor` reads as "unmagnified" and answers accordingly.
  result = 0.0
  if not bOpticCamera.ok or not bCamFov.ok:
    return
  var a = noArgs()
  let container = callPtr(bOpticInstance, nullPtr(), a)
  if container == nil:
    return
  a.reset()
  let cam = callPtr(bOpticCamera, container, a)
  if cam == nil:
    return
  a.reset()
  result = callFloat(bCamFov, cam, a)

# ---------------------------------------------------------------------------
# Effect 1: the per-frame FOV write
# ---------------------------------------------------------------------------

proc applyFov() =
  ## Upstream's `FovController.Update`, on the fast path.
  ##
  ## Runs inside a patched game method, so it is on the game thread and inside
  ## the game's own frame -- which is where a Unity write has to happen. Every
  ## pointer here is resolved fresh and dropped before the call returns: rule 4
  ## in docs/PERF.md, and the reason nothing in this file stores one.
  if not bSetFov.ok:
    return
  let now = nowMs()
  if gLastFovMs != 0'i64 and now - gLastFovMs < FovIntervalMs:
    return
  gLastFovMs = now

  var a = noArgs()
  let w = callPtr(bWorld, nullPtr(), a)
  if w == nil: return
  a.reset()
  let player = callPtr(bMainPlayer, w, a)
  if player == nil: return
  a.reset()
  let pwa = callPtr(bPwa, player, a)
  if pwa == nil: return

  a.reset()
  let cm = callPtr(bCamInstance, nullPtr(), a)
  if cm == nil: return
  a.reset()
  let cam = callPtr(bCamCamera, cm, a)
  if cam == nil: return

  # The base is captured once, before anything is written, and never re-read.
  # Reading it every frame would be a feedback loop: this mod's own output is
  # the camera's field of view, so the second frame would multiply the first
  # frame's product. The cost is that changing the in-game FOV slider mid-raid
  # does not take effect until the next one, which is stated rather than hidden.
  if gBaseFov <= 0.0:
    a.reset()
    let seen = callFloat(bCamFov, cam, a)
    if seen <= 0.0:
      return
    gBaseFov = seen
    info "FOV Fix: base field of view captured at " & $gBaseFov

  a.reset()
  let aiming = callBool(bIsAiming, pwa, a)

  var optic = false
  if aiming and bScope.ok:
    a.reset()
    let scope = callPtr(bScope, pwa, a)
    if scope != nil:
      if not gOpticClassTried:
        bindOpticIsOptic(scope)
      if bIsOptic.ok:
        a.reset()
        optic = callBool(bIsOptic, scope, a)

  var mult = 1.0
  if aiming:
    mult = (if optic: cfgOpticFovMulti else: cfgNonOpticFovMulti)

  let target = gBaseFov * mult
  a.reset()
  addFloat(a, target)
  if gSetFovArgc == 3:
    addFloat(a, 0.0)     # lerp time: upstream sets the value outright
    addBool(a, true)
  callVoid(bSetFov, cm, a)
  gFovWrites = gFovWrites + 1

# ---------------------------------------------------------------------------
# Effect 2: CalculateScaleValueByFov
# ---------------------------------------------------------------------------

proc onScaleValue(target, args: string): HookResult =
  ## Upstream's `CalculateScaleValueByFovPatch`: the body is replaced by a
  ## constant, so the viewmodel stops being rescaled as the field of view
  ## changes. A prefix that returns a `__result` and `false` is exactly
  ## `stopWith`, and this is the case where the two are the same thing.
  gScaleHits = gScaleHits + 1
  result = stopWith($cfgFovScale)

proc armScaleFix() =
  if not cfgEnableFovScaleFix:
    gScaleState = "off (enableFovScaleFix is false)"
    return
  var params: seq[string] = @[]
  var ret = ""
  if not signatureOf(TyPlayer, "CalculateScaleValueByFov", -1, params, ret):
    gScaleState = "refused: no " & TyPlayer & "::CalculateScaleValueByFov"
    return
  if ret != "System.Single":
    gScaleState = "refused: it is " & describeSig(params, ret) &
                  " and this replaces a float"
    return
  if not argsSafe(params):
    gScaleState = "refused: " & describeSig(params, ret) &
                  " has a value-type parameter, which the host would report " &
                  "as a reference"
    return
  if hookArgs(TyPlayer & "::CalculateScaleValueByFov", onScaleValue) == Ok:
    gScaleState = "armed, returning " & $cfgFovScale
  else:
    gScaleState = "refused: " & lastError()

# ---------------------------------------------------------------------------
# Effect 3: SightComponent::get_GetCurrentSensitivity
# ---------------------------------------------------------------------------

proc onScopeSensitivity(target, args: string): HookResult =
  ## Upstream's `ScopeSensitivityPatch`. The magnification→sensitivity table is
  ## the arithmetic at the top of this file; what it is applied to is the optic
  ## camera's field of view, read live on the fast path.
  ##
  ## The one thing this cannot do is tell *which* sight is being asked: a hook
  ## is not given the instance it fired on, only the declared arguments, and
  ## this getter has none. In a raid the sight being queried for sensitivity is
  ## the one being aimed through, which is the one the optic camera is showing,
  ## so the answer is the same -- but it is an assumption and it is written
  ## down rather than left implied.
  gSensHits = gSensHits + 1
  result = stopWith($zoomSensFor(opticFieldOfView()))

proc armScopeSensitivity() =
  if not cfgChangeMouseSensitivity:
    gSensState = "off (changeMouseSensitivity is false)"
    return
  var params: seq[string] = @[]
  var ret = ""
  if not signatureOf(TySight, "get_GetCurrentSensitivity", -1, params, ret):
    gSensState = "refused: no " & TySight & "::get_GetCurrentSensitivity"
    return
  if ret != "System.Single":
    gSensState = "refused: it is " & describeSig(params, ret) &
                 " and this replaces a float"
    return
  if not argsSafe(params):
    gSensState = "refused: " & describeSig(params, ret) &
                 " has a value-type parameter"
    return
  if not bindOpticCamera():
    gSensState = "refused: the optic camera is unreachable (" &
                 gOpticChainState & "), so the table has no field of view " &
                 "to read and would be answering from nothing"
    return
  if hookArgs(TySight & "::get_GetCurrentSensitivity", onScopeSensitivity) == Ok:
    gSensState = "armed, " & gOpticChainState
  else:
    gSensState = "refused: " & lastError()

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
  # The frame driver is a watched target and not a second detour on the same
  # method: two patches on one compiled function would be a detour of a
  # detour. One hook, and the dispatcher decides what else it means.
  if target == FrameDriver:
    applyFov()

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
  success "FOV Fix: the game world is up"

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

  # Binding happens here rather than in `onLoad`, and that is not a detail:
  # `findClass` walks every loaded assembly, and at load time the game's own
  # assemblies are not among them, so a binding made then would correctly
  # refuse and never be retried.
  if not openRuntime():
    gFovState = "refused: the IL2CPP runtime could not be bound from the mod"
    gScaleState = gFovState
    gSensState = gFovState
    warn "FOV Fix: " & gFovState
  else:
    if bindFovChain():
      gFovState = "armed, SetFov taking " & $gSetFovArgc & " argument(s)"
    armScaleFix()
    armScopeSensitivity()

  info "FOV Fix: per-frame FOV write -- " & gFovState
  info "FOV Fix: CalculateScaleValueByFov -- " & gScaleState
  info "FOV Fix: scope sensitivity -- " & gSensState

  if not cfgVerifyHooks:
    info "verifyHooks is off; not attaching the target-verification detours"
    # The frame driver is one of those detours, so the FOV write goes with it.
    if gFovState.len > 0 and bSetFov.ok:
      warn "the per-frame FOV write rides on the " & FrameDriver &
           " detour and is therefore also off"
    return

  # The exact methods the original patched, in the original's order. Sixteen
  # patch slots exist; this uses six, two of which now do work rather than
  # only counting.
  watch("EFT.Animations.ProceduralWeaponAnimation::UpdateWeaponVariables",
        "PwaWeaponParamsPatch -- where upstream learns the current weapon")
  watch("EFT.Animations.ProceduralWeaponAnimation::LerpCamera",
        "LerpCameraPatch -- not ported: Vector3 fields, and no instance")
  watch(FrameDriver,
        "FreeLookPatch -- not ported; carries the per-frame FOV write")
  # An effect that already hooked its target is its own watcher: `hookArgs`
  # and `hook` both go through `patch`, and two patches on one compiled
  # function would be a detour of a detour.
  if armed(gScaleState):
    info "watching EFT.Player::CalculateScaleValueByFov through the " &
         "replacing hook (CalculateScaleValueByFovPatch)"
  else:
    watch("EFT.Player::CalculateScaleValueByFov",
          "CalculateScaleValueByFovPatch -- viewmodel/ribcage scale")
  watch("EFT.Player.FirearmController::get_AimingSensitivity",
        "AimingSensitivityPatch -- not ported: it scales, a prefix replaces")
  if armed(gSensState):
    info "watching EFT.InventoryLogic.SightComponent::" &
         "get_GetCurrentSensitivity through the replacing hook " &
         "(ScopeSensitivityPatch)"
  else:
    watch("EFT.InventoryLogic.SightComponent::get_GetCurrentSensitivity",
          "ScopeSensitivityPatch -- per-scope sensitivity")

proc reportEffect(name, state: string; hits: int) =
  if armed(state):
    if hits > 0:
      success "  " & name & ": " & state & " -- applied " & $hits & " times"
    else:
      warn "  " & name & ": " & state & " -- but it never applied; the " &
           "method it replaces is not being called on this build"
  else:
    warn "  " & name & ": " & state

proc reportWatch() =
  if gWatchNames.len > 0:
    info "FOV Fix target verification, after roughly a minute in raid:"
    for i in 0 ..< gWatchNames.len:
      if gWatchCounts[i] > 0:
        success "  " & gWatchNames[i] & " fired " & $gWatchCounts[i] & " times"
      else:
        warn "  " & gWatchNames[i] & " never fired -- it is patched but the " &
             "game does not call it; treat the name as stale"
  info "FOV Fix, what was actually applied:"
  reportEffect("per-frame FOV write", gFovState, gFovWrites)
  reportEffect("CalculateScaleValueByFov", gScaleState, gScaleHits)
  reportEffect("scope sensitivity", gSensState, gSensHits)
  info "  not ported, and why: LerpCamera and the FOV slider range need the " &
       "instance a hook fired on, which is not reported; LerpCamera and Look " &
       "also need Vector2/Vector3, which no path here reads; " &
       "get_AimingSensitivity scales the original's result, which needs a " &
       "postfix; the toggle-zoom key needs keyboard input. See the module " &
       "comment."

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
  info "note: the camera offsets, aim speeds and toggle-zoom settings above " &
       "are read and reported but not applied -- the patches that would use " &
       "them are the ones this build cannot express. The module comment says " &
       "which capability each one is waiting on."
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
  if not gReported and gElapsedMs > 60_000 and world.fired:
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
