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
## WHAT IT CHANGES, WHAT IT ASSUMES, AND WHAT IT HAS NEVER BEEN RUN AGAINST
## ---------------------------------------------------------------------------
##
## **What it changes in the game.** Three writes, no more:
##
##  1. Roughly 250 times a second, the main camera's field of view is set to the
##     base FOV captured on the first frame, multiplied by `opticFovMulti` while
##     aiming through a magnified sight and `nonOpticFovMulti` while aiming
##     otherwise. Not aiming, the multiplier is 1 and the write is the base
##     value back again.
##  2. `Player::CalculateScaleValueByFov` is replaced by the constant
##     `fovScale`, when `enableFovScaleFix` is on.
##  3. `SightComponent::get_GetCurrentSensitivity` is replaced by a table lookup
##     on the optic camera's live field of view, when `changeMouseSensitivity`
##     is on.
##
## Everything else in `config.json` is read, printed and **not applied** -- the
## camera offsets, the aim speeds, the toggle-zoom keys. Each is blocked by one
## named missing capability, listed under "WHAT IS STILL NOT EXPRESSIBLE".
##
## **What it assumes about the client.** Two static members by name
## (`EFT.GameWorld::get_Instance`, `CameraManager::get_Instance`) and nine
## instance members bound **against the object they are reached on** rather than
## against any name written here -- because a bound call is non-virtual by
## construction and half this chain hands over subclasses (SPT's raid world, the
## `LocalPlayer`, and `CurrentScope`, whose declared type is not the type of the
## object it returns). `SetFov`'s parameter list is read out of the runtime and
## accepted only as `(Single, Single, Boolean)` or `(Single)`; anything else is
## refused with the signature printed. A wrong name is a refused binding with a
## `why` line and an effect that does nothing, never a wrong write.
##
## The one thing assumed rather than checked is that the sight being asked for
## sensitivity is the sight the optic camera is showing. A hook is not told the
## instance it fired on, and in a raid there is one sight being aimed through --
## but it is an assumption and it is written down at the call site too.
##
## **It has never been run against BSG's game.** Not once. Every EFT name here
## is from the pre-1.0 C# surface; post-1.0 is a different build.
## `aowl run mods/fov` prints the whole binding report offline, and
## `verifyHooks` prints the live one a minute into a raid. Read one of those
## before believing any of the above happened.
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
##     Harmony prefix that returns `false` with a `__result`; `hookReturn` is
##     the postfix half, and on a revision-4 host `hookReturnTyped` is that
##     same postfix reading the registers the detour already saved instead of
##     a JSON description of them.
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
##      game thread. Where that method cannot be detoured the driver falls back
##      to `everyMain`, and **only** when the host confirms that its
##      main-thread drain has fired on Unity's thread. This file used to say
##      flatly that `invoke_main` is not Unity's main thread; that stopped
##      being true when the host started draining its queue from inside a
##      per-frame game method of its own, and the correction is made here
##      rather than silently because it is the reason there is a second
##      driver. Neither driver is switched off by `verifyHooks` any more.
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
## First, a correction, because two of the four below used to rest on it. This
## file used to say that a hook is not told which instance it fired on. **That
## is no longer true.** `hookArgs` delivers an object:
##
##     {"this":{"handle":3,"type":"EFT.Player"},"args":[1,2.5]}
##
## `this` is Harmony's `__instance`, and a static method's is `null` rather than
## absent. It is also no longer true that a value-type argument would have the
## host take a GC handle to a register holding float bits -- the host asks the
## runtime now, an enum arrives as its number, and a wide value type arrives as
## `{"valueType":"..."}`, named and refused rather than invented. Both
## corrections are written here rather than made silently, because between them
## they were the stated reason for four missing features.
##
## What replaced the first has now expired too, and the correction matters as
## much as the first one did. It used to read: "`this` arrives as a host
## `Handle`, and no ABI entry point turns one into the raw pointer the fast path
## needs" -- so anything reached through it was on the boxed path at ~1 us a
## call, which per player per frame is a frame tax rather than a feature.
##
## **ABI revision 3 turns a handle into an address.** `thisPointer(args)` in a
## hook handler gives the `Il2CppPtr` that `bindOnObject`, `callFloat` and
## `readFloat` take, measured at 8 ns against 1148 ns for the boxed read it
## replaces (docs/PERF.md). The address is good for the length of the handler
## and no longer -- the host reclaims the handle when it returns, and refuses to
## give an address for it afterwards rather than handing back a stale one.
##
## * **`ProceduralWeaponAnimation::LerpCamera`** -- upstream's `LerpCameraPatch`
##   replaces the ADS camera lerp: it reads and writes the instance's `Vector3`
##   camera-offset fields and its per-axis speeds. Every capability blocker this
##   file has listed for it is now gone. `this` is delivered, an address for it
##   costs 8 ns, and a `Vector3` is reachable -- `bindRaw`/`ShapedArgs` binds a
##   method by its *native slot shape*, which is what Win64 does with a 12-byte
##   aggregate (docs/PERF.md; `mods/sain`'s `tryShaped` for the guard
##   discipline). What is left is not a capability and not a cost: it is that
##   this port cannot confirm the names of the camera-offset fields on
##   `ProceduralWeaponAnimation` against a running post-1.0 build, and writing a
##   camera offset to a field guessed by name is the one kind of approximation
##   the rest of this file refuses. That is a much shorter distance to travel
##   than it was, and it is a different problem.
##
## * **`Player::Look`** -- upstream's `FreeLookPatch` clamps the free-look angles
##   on `__instance`. The cost objection is gone with the rest; what stops it is
##   unchanged and is about the payload rather than the instance. The angles
##   arrive as a `Vector2`, which is passed by hidden pointer and reported as
##   `{"valueType":"UnityEngine.Vector2"}` -- named and refused rather than
##   invented -- so there is nothing in the payload to clamp. A postfix does not
##   help either: `Look` returns void.
##
## * **`FirearmController::get_AimingSensitivity`** -- **ported.** Upstream
##   injects `ref float ____aimingSens`, the instance's private field, and
##   scales it; this is a postfix that takes the getter's own result and
##   multiplies it. That is the same number by a shorter route -- Harmony
##   reaches for the private field because Harmony offers a way to, and the
##   getter returns it -- so nothing here has to know a field name on a build
##   nobody has dumped. On a revision-4 host it is a **typed** postfix
##   (`hookReturnTyped`): the float comes out of XMM0 and the replacement goes
##   back into the return slot. Measured from inside this DLL against a
##   stand-in method of the same shape: **44 ns a call**, against ~1600 ns for
##   the JSON form that formats one float to text and parses another back --
##   thirty-six-fold, and the JSON figure is the noisiest row in
##   docs/PERF.md's table because it is the only one making allocator round
##   trips. Which of the two armed is in the effect's own state line, and the
##   effect times itself in place and prints that too. See "Effect 4".
##
## * **The toggle-zoom key.** `zoomToggleKey`, `holdToZoom` and the three
##   `*ToggleZoomMulti` settings need to know whether a key is down.
##
##   Half of what this used to say has expired and is worth correcting rather
##   than quietly dropping. It read "`UnityEngine.Input::GetKey` takes a
##   `KeyCode`, **which is an enum**, and mapping the configured names onto its
##   numeric values by hand is precisely the kind of guess this port does not
##   make" -- and the emphasis was doing real work, because an enum argument
##   used to be refused outright by the host as something it "cannot build from
##   a JSON scalar". That is gone: **an enum is a number in both directions**
##   now (docs/IL2CPP.md), so `GetKey` is callable the moment this mod has a
##   number to pass it.
##
##   What is left is the other half, unchanged and still disqualifying: this
##   mod has a *string* out of `config.json` -- `"M"`, `"KeypadMultiply"` --
##   and turning one into a `KeyCode` ordinal means writing Unity's enumeration
##   out by hand from memory. That is a guess about a value, not a missing
##   capability, and it is the same class of refusal as the camera-offset field
##   names above. The settings are read, reported and carried; nothing acts on
##   them.
##
## * **The base-FOV slider range** (`minBaseFov`/`maxBaseFov`) -- upstream's
##   `FovRangePatch` rewrites the slider bounds on a `GameSettingsTab` instance.
##   The instance is delivered now and this one fires when a menu opens, so the
##   cost objection does not apply -- it is genuinely expressible. What stops it
##   is the last thing this port will not do: it would have to name the slider
##   field on `GameSettingsTab`, and that name cannot be confirmed from here.
##   The refusal is now about a name rather than a capability, which is a much
##   shorter distance to travel.
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
import aowlspt/settings # the F12 settings schema this mod declares
import aowlspt/il2cpp   # the runtime's own C API, for signature checks
import aowlspt/fast     # bind once, call in ~10 ns — docs/PERF.md
import aowlspt/json     # reading the host's main-thread report
import aowlspt/fixture  # where a self-test's runtime path may come from

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
# The F12 settings schema
# ---------------------------------------------------------------------------
#
# What loadConfig reads, declared so the in-game settings screen can draw a
# control per key. `implemented` mirrors the module comment exactly: three
# writes reach the game (the FOV multipliers, the FOV-scale fix, the
# sensitivity table), and everything else is read, reported and carried but not
# yet acted on — so it is declared `implemented = false` with the missing
# capability named, rather than drawn as if it worked.

proc fovSchema(): seq[Setting] =
  result = @[
    floatSetting("opticFovMulti", "Optic FOV multiplier", 1.0,
                 lo = 0.1, hi = 2.0, step = 0.01, category = "FOV",
                 description = "FOV scale while aiming a magnified sight"),
    floatSetting("nonOpticFovMulti", "Non-optic FOV multiplier", 1.0,
                 lo = 0.1, hi = 2.0, step = 0.01, category = "FOV",
                 description = "FOV scale while aiming iron sights / reflex"),
    boolSetting("enableFovScaleFix", "FOV scale fix", false, category = "FOV",
                description = "Replace Player.CalculateScaleValueByFov with a constant"),
    floatSetting("fovScale", "FOV scale value", 1.0, lo = 0.1, hi = 3.0,
                 step = 0.01, category = "FOV"),
    intSetting("maxBaseFov", "Max base FOV", 110, lo = 30, hi = 140,
               category = "FOV", implemented = false,
               description = "Read; the FOV-range slider patch is not expressible yet"),
    intSetting("minBaseFov", "Min base FOV", 30, lo = 10, hi = 120,
               category = "FOV", implemented = false,
               description = "Read; the FOV-range slider patch is not expressible yet"),

    boolSetting("changeMouseSensitivity", "Scale mouse sensitivity", true,
                category = "Sensitivity",
                description = "Replace get_GetCurrentSensitivity with a magnification lookup"),
    floatSetting("oneSensMulti", "1x sensitivity", 0.75, lo = 0.0, hi = 2.0,
                 step = 0.01, category = "Sensitivity"),
    floatSetting("fourSensMulti", "4x sensitivity", 0.2, lo = 0.0, hi = 2.0,
                 step = 0.01, category = "Sensitivity"),
    floatSetting("highSensMulti", "High-mag sensitivity", 0.01, lo = 0.0,
                 hi = 2.0, step = 0.001, category = "Sensitivity"),

    keybindSetting("zoomToggleKey", "Toggle-zoom key", "M",
                   category = "Toggle zoom", implemented = false,
                   description = "Read; needs KeyCode-enum name mapping, not yet expressible"),
    boolSetting("holdToZoom", "Hold to zoom", true, category = "Toggle zoom",
                implemented = false, description = "Read; toggle-zoom is not wired yet"),

    floatSetting("rifleCameraZOffset", "Rifle camera Z offset", 0.025,
                 lo = -0.2, hi = 0.2, step = 0.005, category = "Camera",
                 implemented = false,
                 description = "Read; the camera-offset write is not expressible yet"),
    floatSetting("rifleAimSpeedZ", "Rifle aim speed Z", 3.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Camera", implemented = false,
                 description = "Read; the aim-speed write is not expressible yet"),

    boolSetting("verifyHooks", "Verify hooks at load", true, category = "Advanced",
                description = "Assert each detour bound before trusting it")]

proc onFovSettings(url, body, session: string): string =
  ## GET: the declared schema with current values folded in, for the settings
  ## UI. POST: the one edit the panel is writing back — applied to config.json,
  ## then re-read so the effect is live and the returned schema shows the saved
  ## value.
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
    if st == Ok: loadConfig()
  result = declaredSchemaReply(st).text

proc onFovSettingsReset(url, body, session: string): string =
  let st = resetFromBody(body)
  if st == Ok: loadConfig()
  result = declaredSchemaReply(st).text

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
  TyFirearm = "EFT.Player.FirearmController"

  FrameDriver = "EFT.Player::Look"
    ## The per-frame hook the FOV write rides on, and the first of two drivers.
    ##
    ## It is a method the game already calls, so it runs on the game's thread
    ## by construction rather than on anyone's assurance. `Look` is upstream's
    ## `FreeLookPatch` target, so it is one this port already watches, and it
    ## is reached once per player per frame -- every bot's included, which is
    ## what `FovIntervalNs` is compensating for.
    ##
    ## **A correction, because this comment used to be the reason there was
    ## only one driver.** It read: "the alternative — `onUpdate` — runs on the
    ## host's own attached thread, and `invoke_main` queues onto that same
    ## thread rather than Unity's. Writing a camera's field of view from there
    ## is not legal." The first half is still true and the second half is not.
    ## The IL2CPP host detours a per-frame game method of its own and drains
    ## the `invoke_main` queue from inside it, so on a host where that drain
    ## bound, `invoke_main` *is* Unity's thread -- and `everyMain` is a
    ## callback on it, once per drain, holding one scheduler slot. Where the
    ## drain could not bind the queue falls back to the host's own thread and
    ## the old sentence applies again in full, which is why the second driver
    ## below is gated on the host's own answer rather than on this note.

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

proc argsUsable(params: seq[string]; why: var string): bool =
  ## Whether this method's arguments will arrive in a form this mod can use.
  ##
  ## **This used to be a safety guard and is not one any more, and the change
  ## is worth stating rather than quietly making.** The host once built the
  ## argument array from the declared type name alone: primitives and strings
  ## it formatted, and everything else it treated as a reference -- taking the
  ## register, calling `il2cpp_gchandle_new` on it and reporting a handle. For
  ## a `Vector2`, a `Vector3` or an enum that register holds float bits or a
  ## small integer, and handing it to the collector was not a wrong answer, it
  ## was a crash in the middle of a game method. So this refused any parameter
  ## `classifyType` would not classify.
  ##
  ## The host asks the runtime now (`shapeOfType`): an enum arrives as its
  ## integer, a value type too large for a register arrives as
  ## `{"valueType":"..."}` -- named and refused rather than invented -- and a
  ## type it cannot classify arrives as `{"type":"..."}`. None of those is a
  ## crash, so there is nothing left to be *safe* from.
  ##
  ## What is left is narrower and is a usability question: a parameter this mod
  ## would have to *read* which arrives as a placeholder is one it cannot
  ## decide on. Only the wide-value-type case is that. The reason is reported
  ## so each caller can say whether it cared.
  ##
  ## **This gate could not fail until today.** `classifyType` used to answer
  ## `fkPtr` for every non-primitive the resolver could find, so `== fkNone`
  ## was false for every real EFT type and the body below never executed. It
  ## answers honestly now, which makes this a live test for the first time --
  ## and a live test has to agree with what it is predicting. That is the
  ## host's `shapeOfType` (host/Aowlspt.Host.Il2Cpp/invoke.nim):
  ##
  ##   * no class for the declared type            -> `{"type":"..."}`
  ##   * a value type of 1..8 payload bytes        -> its number
  ##   * any other value type                      -> `{"valueType":"..."}`
  ##
  ## Payload is the *reported instance size minus the box header*, and the
  ## header is measured (`boxHeaderBytes`) rather than assumed. This used to
  ## test `classInstanceSize(c) > 24`, which is that predicate only on a
  ## runtime whose header happens to be 16 -- precisely the assumption
  ## `boxHeaderBytes` exists to prevent. `UnityEngine.Vector2`, the parameter
  ## the `Look` refusal below is *about*, is the type that would have been
  ## mis-answered on a runtime reporting payload sizes.
  why = ""
  result = true
  let header = boxHeaderBytes(rt)
  for i in 0 ..< params.len:
    if classifyType(rt, params[i]) != fkNone:
      # A primitive, a reference, or a value type that fits a register: the
      # host reports a value for all three.
      continue
    let c = findClass(rt, params[i])
    if c == nil:
      # The name did not resolve here. The host classifies from the declared
      # *type*, which resolves for generics and arrays where the printed name
      # does not, so this is not proof of a placeholder -- but calling a
      # parameter readable on the strength of a lookup that failed is the one
      # direction that matters.
      if why.len > 0: why.add ", "
      why.add "argument " & $i & " (" & params[i] &
              ") is a type this mod cannot resolve by name, so it cannot say " &
              "whether the host will report a value or a placeholder"
      result = false
      continue
    if not classIsValueType(rt, c):
      continue
    let payload = classInstanceSize(rt, c) - header
    if payload <= 0 or payload > 8:
      if why.len > 0: why.add ", "
      why.add "argument " & $i & " (" & params[i] & ") is a " & $payload &
              "-byte value type, so it arrives by hidden pointer and the " &
              "host reports {\"valueType\":\"" & params[i] & "\"} rather " &
              "than a value"
      result = false

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
var gAimSensState = "not attempted"
var gAimSensHits = 0
var gAimSensTyped = false
  ## Which of the two forms armed. Reported in the state line rather than left
  ## implied, because the two differ by roughly thirty-sixfold and "armed"
  ## alone would hide that.
var gAimSensNs = 0'i64
var gAimSensSamples = 0

proc armed(state: string): bool =
  ## An effect state reads "armed..." or "refused: ..." or "off (...)". Only
  ## the first means a hook was installed, and that is the question every
  ## caller of this actually has.
  result = state.len >= 5 and state.substr(0, 4) == "armed"

# ---------------------------------------------------------------------------
# Binding against the object, once
# ---------------------------------------------------------------------------
#
# A bound call is **non-virtual by construction**: it jumps to a compiled body.
# So `bindMethod(rt, "EFT.Player", "get_ProceduralWeaponAnimation", 0)` binds
# `EFT.Player`'s body and calls it even when the object in hand is the
# `LocalPlayer` the game actually hands over -- silently, with a plausible
# answer. Half this chain is like that: the raid `GameWorld` is a subclass, the
# main player is a subclass, and `CurrentScope`'s declared type is not the type
# of the object it returns.
#
# `bindOnObject` binds against the class the object *is*, walking its base
# chain, so there is no name to be wrong about. What it cannot do is happen
# before the object exists -- which puts the attempt on the frame path, and that
# is fine exactly once and ruinous every frame: `bindOnObject` walks a whole
# base chain and the self-test measures it in microseconds. A *refused* binding
# retried per frame is the worst case, because it never succeeds and never stops
# costing.
#
# So an attempt is keyed on the class it was made against. The first object of
# that class binds; after that it is one `il2cpp_object_get_class` and one
# pointer compare, whether the bind succeeded or not. A different class -- a
# different `Player` subclass, a scope swap that changes the sight's type -- is
# a new question and is asked again. That is `mods/sain`'s `LazyCall` rule,
# for the same reason.

type
  ObjBind = object
    b: Binding
    cls: Il2CppClass     ## the class the attempt was made against
    tried: bool
    why: string

proc noObjBind(): ObjBind =
  ObjBind(b: Binding(ok: false, why: "", target: "", fn: nullPtr(),
                     info: nullPtr(), argc: 0'i32, slots: 0'i32, mask: 0'u32,
                     ret: fkNone, isStatic: false, bindNs: 0'i64),
          cls: cast[Il2CppClass](0), tried: false, why: "not attempted")

proc statedKindsDisagree(b: Binding; kinds: openArray[FastKind];
                         ret: FastKind): string =
  ## What the runtime says about a binding whose register classes this mod
  ## **asserted**, or `""` when the two agree.
  ##
  ## `bindMethod` infers the signature from the runtime's own metadata and
  ## refuses what it cannot classify. `bindOnObject` cannot: it has a class
  ## rather than a name, and the inference path takes a name -- so every call
  ## bound here states its kinds, and `fast.nim` says in as many words that
  ## "the mod is asserting the register classes, and it is on the mod to be
  ## right".
  ##
  ## An assertion nobody checks is a remembered signature, which is the thing
  ## this whole file is arranged not to rely on. And the failure it produces is
  ## the worst one available rather than a crash: a `System.Double` asserted as
  ## `fkF32` reads the wrong half of XMM0 and answers a plausible number; a
  ## `System.Int32` asserted as `fkBool` answers `true` for any value whose low
  ## byte is not zero. Both arrive with `ok` true and both get acted on.
  ##
  ## So the assertion is checked against the method the bind actually landed
  ## on. `Binding.info` is that `MethodInfo*`, which is the whole cost of the
  ## check: no second lookup, and it happens once per class rather than per
  ## call. `fkNone` from the runtime is a disagreement rather than a pass --
  ## it means a value type wider than a register, which does not travel in the
  ## register this mod named at all.
  result = ""
  if not b.ok or b.info == nil:
    return
  let n = methodParamCount(rt, b.info)
  if n != kinds.len:
    result = b.target & " declares " & $n & " parameter(s); this mod bound " &
             "it as " & $kinds.len
    return
  for i in 0 ..< kinds.len:
    let d = classifyDeclared(rt, methodParam(rt, b.info, i))
    if d != kinds[i]:
      result = b.target & ": parameter " & $i & " is " & describe(d) &
               " and this mod passed " & describe(kinds[i])
      return
  let rk = classifyDeclared(rt, methodReturnType(rt, b.info))
  if rk != ret:
    result = b.target & ": returns " & describe(rk) &
             " and this mod read " & describe(ret)

proc ensureCall(o: var ObjBind; obj: Il2CppPtr; member: string;
                kinds: openArray[FastKind]; ret: FastKind): bool =
  ## Bind `member` against the object's own class, at most once per class, and
  ## check the kinds this mod asserted against the method it landed on.
  if obj == nil:
    return false
  let c = objectClass(rt, obj)
  if c == nil:
    return false
  if (not o.tried) or o.cls != c:
    o.cls = c
    o.tried = true
    o.b = bindOnObject(rt, obj, member, kinds, ret)
    o.why = o.b.why
    let disagreement = statedKindsDisagree(o.b, kinds, ret)
    if disagreement.len > 0:
      # The bind succeeded and is being thrown away, which is the point: a
      # binding that resolves against a signature this mod does not have is
      # the one that answers a plausible number. `get_fieldOfView` returning a
      # `System.Double` on some future build would otherwise set the camera's
      # field of view from the wrong half of a register.
      o.b.ok = false
      o.why = disagreement
      o.b.why = disagreement
  result = o.b.ok

proc noKinds(): seq[FastKind] =
  ## An empty argument list for `bindOnObject`. A bare `[]` literal has no type
  ## for nimony to infer at that call site, so the empty seq is named once.
  result = @[]

# The FOV chain. The two statics are bound by name -- `bindMethod` is right for
# a static, which has no subclass to dispatch on -- and everything else is bound
# against the object it is reached through. Declared bare and assigned from a
# proc: a nimony `--app:lib` global initialised by a *call* is silently left
# zeroed, and a zeroed `Binding` has `ok = false`, so it fails safe but never
# becomes true. See fast.nim's rule 1.
var bWorld: Binding            ## EFT.GameWorld::get_Instance, static
var bCamInstance: Binding      ## CameraManager::get_Instance, static
var bOpticInstance: Binding    ## the optic camera container's Instance, static

var obMainPlayer: ObjBind      ## on the world object
var obPwa: ObjBind             ## on the player object
var obIsAiming: ObjBind        ## on the weapon animation object
var obScope: ObjBind           ## on the weapon animation object
var obIsOptic: ObjBind         ## on the scope object, whose class is not CurrentScope's declared type
var obCamCamera: ObjBind       ## on the camera manager object
var obCamFov: ObjBind          ## on the UnityEngine.Camera object
var obSetFov: ObjBind          ## on the camera manager object
var obOpticCamera: ObjBind     ## on the optic camera container object

var gSetFovArgc = 0
var gOpticChainState = "not attempted"
var gBaseFov = 0.0
var gLastFovTicks = 0'i64
var gFovNs = 0'i64
var gFovSamples = 0
var gFovBoundSaid = false

const
  FovIntervalNs = 4_000_000'i64
    ## The FOV write is idempotent and the hook it rides on fires once per
    ## player per frame -- including every bot's. Rate-limiting to ~250 Hz means
    ## a raid full of bots costs one write per frame rather than forty, and a
    ## 240 Hz client still gets one per frame.
    ##
    ## The clock is `fast`'s `perfCounter`, not the host's `nowMs`. An earlier
    ## revision used milliseconds and said in a comment that `perfCounter` was
    ## an `importc ... nodecl` only usable inside `fast.nim`'s own translation
    ## unit. That was true and is not any more -- it is an ordinary proc now
    ## (docs/PERF.md says so, and names this file's excuse as one of the two
    ## that prompted the change). A millisecond gate on a 240 Hz frame is a gate
    ## whose granularity is a quarter of the interval it is enforcing.

  CostSamples = 512
    ## How many writes are timed before the measurement stops. Two `perfCounter`
    ## calls are about forty nanoseconds, the same order as the work, so
    ## measuring forever would be paying for a number nobody reads twice.

proc bindFovStatics(): bool =
  ## The two members that have no object to bind against yet. Everything else in
  ## the chain is bound on the first frame the object it lives on exists.
  obMainPlayer = noObjBind()
  obPwa = noObjBind()
  obIsAiming = noObjBind()
  obScope = noObjBind()
  obIsOptic = noObjBind()
  obCamCamera = noObjBind()
  obCamFov = noObjBind()
  obSetFov = noObjBind()
  obOpticCamera = noObjBind()

  # Both are attempted before either is judged, so the report has a `why` for
  # each. An early return here left the second `Binding` zeroed, and a zeroed
  # one reports an empty reason -- which reads as "no reason given" rather than
  # "never asked".
  bWorld = bindMethod(rt, TyGameWorld, "get_Instance", 0)
  bCamInstance = bindMethod(rt, TyCamera, "get_Instance", 0)
  if not bWorld.ok:
    gFovState = "refused: " & bWorld.why
    return false
  if not bCamInstance.ok:
    gFovState = "refused: " & bCamInstance.why
    return false

  # `SetFov` is the one place upstream's call shape has to be confirmed rather
  # than remembered. Two overloads are accepted, and only if the runtime says
  # the parameters are what this would pass; anything else is refused with the
  # signature printed, which is the line somebody needs in order to fix it.
  # The arity is settled here, by name; the *binding* is taken later against the
  # camera manager object, because a subclass may override it.
  var params: seq[string] = @[]
  var ret = ""
  if signatureOf(TyCamera, "SetFov", 3, params, ret) and params.len == 3 and
     params[0] == "System.Single" and params[1] == "System.Single" and
     params[2] == "System.Boolean":
    gSetFovArgc = 3
  elif signatureOf(TyCamera, "SetFov", 1, params, ret) and params.len == 1 and
       params[0] == "System.Single":
    gSetFovArgc = 1
  else:
    discard signatureOf(TyCamera, "SetFov", -1, params, ret)
    gFovState = "refused: " & TyCamera & "::SetFov is " &
                describeSig(params, ret) &
                ", which is neither (Single, Single, Boolean) nor (Single); " &
                "this port will not guess what the extra parameters mean"
    return false

  gFovState = "arming: SetFov takes " & $gSetFovArgc &
              " argument(s); waiting for a world and a camera to bind the " &
              "rest against"
  result = true

proc setFovKinds(): seq[FastKind] =
  ## The register classes of `SetFov`'s arguments, at the arity the runtime
  ## reported. Stated rather than inferred because `bindOnObject` cannot infer:
  ## it has a class rather than a name, and `bindMethod`'s inference path takes
  ## a name. The types themselves came from the runtime in `bindFovStatics`, so
  ## nothing here is remembered.
  result = @[]
  result.add fkF32
  if gSetFovArgc == 3:
    result.add fkF32
    result.add fkBool

proc bindOpticCamera(): bool =
  ## The optic camera, for the sensitivity table. Its container was renamed more
  ## than once, so both spellings are tried and the one that resolves is
  ## reported -- an empirical answer rather than a remembered one. Only the
  ## static `Instance` is bound here; `get_Camera` is bound against the
  ## container object the first time one exists.
  if bOpticInstance.ok:
    return true
  var owner = "EFT.CameraControl.OpticCameraManagerContainer"
  bOpticInstance = bindMethod(rt, owner, "get_Instance", 0)
  if not bOpticInstance.ok:
    owner = "EFT.CameraControl.OpticCameraManager"
    bOpticInstance = bindMethod(rt, owner, "get_Instance", 0)
  if not bOpticInstance.ok:
    gOpticChainState = "refused: " & bOpticInstance.why
    return false
  gOpticChainState = "bound on " & owner
  result = true

proc opticFieldOfView(): float =
  ## The optic camera's live vertical FOV, or 0 when there is no optic camera --
  ## which `zoomSensFor` reads as "unmagnified" and answers accordingly.
  result = 0.0
  if not bOpticInstance.ok:
    return
  var a = noArgs()
  let container = callPtr(bOpticInstance, nullPtr(), a)
  if container == nil:
    return
  var none = noKinds()
  if not ensureCall(obOpticCamera, container, "get_Camera", none, fkPtr):
    return
  a.reset()
  let cam = callPtr(obOpticCamera.b, container, a)
  if cam == nil:
    return
  if not ensureCall(obCamFov, cam, "get_fieldOfView", none, fkF32):
    return
  a.reset()
  result = callFloat(obCamFov.b, cam, a)

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
  if not bWorld.ok or not bCamInstance.ok:
    return
  let now = perfCounter()
  if gLastFovTicks != 0'i64 and
     nanosBetween(gLastFovTicks, now) < FovIntervalNs:
    return
  gLastFovTicks = now
  let measuring = gFovSamples < CostSamples

  var none = noKinds()
  var a = noArgs()
  let w = callPtr(bWorld, nullPtr(), a)
  if w == nil: return

  if not ensureCall(obMainPlayer, w, "get_MainPlayer", none, fkPtr):
    gFovState = "refused: " & obMainPlayer.why
    return
  a.reset()
  let player = callPtr(obMainPlayer.b, w, a)
  if player == nil: return

  if not ensureCall(obPwa, player, "get_ProceduralWeaponAnimation", none,
                    fkPtr):
    gFovState = "refused: " & obPwa.why
    return
  a.reset()
  let pwa = callPtr(obPwa.b, player, a)
  if pwa == nil: return

  a.reset()
  let cm = callPtr(bCamInstance, nullPtr(), a)
  if cm == nil: return
  if not ensureCall(obCamCamera, cm, "get_Camera", none, fkPtr):
    gFovState = "refused: " & obCamCamera.why
    return
  a.reset()
  let cam = callPtr(obCamCamera.b, cm, a)
  if cam == nil: return

  if not ensureCall(obCamFov, cam, "get_fieldOfView", none, fkF32):
    gFovState = "refused: " & obCamFov.why
    return

  var kinds = setFovKinds()
  if not ensureCall(obSetFov, cm, "SetFov", kinds, fkVoid):
    gFovState = "refused: " & obSetFov.why
    return

  if not gFovBoundSaid:
    gFovBoundSaid = true
    gFovState = "armed, SetFov taking " & $gSetFovArgc & " argument(s) on " &
                obSetFov.b.target
    info "FOV Fix: the per-frame chain bound -- " & gFovState

  # The base is captured once, before anything is written, and never re-read.
  # Reading it every frame would be a feedback loop: this mod's own output is
  # the camera's field of view, so the second frame would multiply the first
  # frame's product. The cost is that changing the in-game FOV slider mid-raid
  # does not take effect until the next one, which is stated rather than hidden.
  if gBaseFov <= 0.0:
    a.reset()
    let seen = callFloat(obCamFov.b, cam, a)
    if seen <= 0.0:
      return
    gBaseFov = seen
    info "FOV Fix: base field of view captured at " & $gBaseFov

  if not ensureCall(obIsAiming, pwa, "get_IsAiming", none, fkBool):
    gFovState = "refused: " & obIsAiming.why
    return
  a.reset()
  let aiming = callBool(obIsAiming.b, pwa, a)

  var optic = false
  if aiming:
    # Optic detection is optional. Without it every aim is treated as
    # unmagnified, which is a *reduced* effect rather than a wrong one, so a
    # refusal here does not veto the write -- but it is recorded and reported.
    if ensureCall(obScope, pwa, "get_CurrentScope", none, fkPtr):
      a.reset()
      let scope = callPtr(obScope.b, pwa, a)
      if scope != nil:
        # `CurrentScope`'s declared type is not the type of the object it
        # returns, and `get_IsOptic` lives on the latter. Binding against the
        # object is what makes that a non-question rather than a lookup this
        # file has to spell.
        if ensureCall(obIsOptic, scope, "get_IsOptic", none, fkBool):
          a.reset()
          optic = callBool(obIsOptic.b, scope, a)

  var mult = 1.0
  if aiming:
    mult = (if optic: cfgOpticFovMulti else: cfgNonOpticFovMulti)

  let target = gBaseFov * mult
  a.reset()
  addFloat(a, target)
  if gSetFovArgc == 3:
    addFloat(a, 0.0)     # lerp time: upstream sets the value outright
    addBool(a, true)
  callVoid(obSetFov.b, cm, a)
  gFovWrites = gFovWrites + 1
  if measuring:
    gFovNs = gFovNs + nanosBetween(now, perfCounter())
    gFovSamples = gFovSamples + 1

proc fovCostNs(): int64 =
  ## The measured cost of one applied FOV write, in nanoseconds, or -1 when
  ## nothing was measured. Reported rather than asserted: docs/PERF.md's numbers
  ## come from a stand-in runtime on one machine, and this is the client the mod
  ## is actually in.
  if gFovSamples <= 0:
    return -1'i64
  result = gFovNs div int64(gFovSamples)

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
  var unusable = ""
  if not argsUsable(params, unusable):
    # This one replaces the body with a constant and reads no argument, so an
    # unreadable parameter would not stop it -- but refusing a hook whose
    # payload this mod cannot fully account for is the conservative side, and
    # the reason is printed rather than implied.
    gScaleState = "refused: " & describeSig(params, ret) & " -- " & unusable
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
  ## The one thing this cannot do is tell *which* sight is being asked, and the
  ## reason used to be stated wrongly here: "a hook is not given the instance it
  ## fired on, only the declared arguments". **A hook is given the instance** --
  ## `hookArgs` carries `this`, `thisPointer` turns it into an address, and this
  ## file says so twice, at :128 and :1607. The claim was false where it
  ## mattered most, in the one place a reader would take it as the reason for a
  ## limitation.
  ##
  ## What is actually true is narrower and does not go away. The host reports
  ## the receiver's *concrete class name* and a handle, which is enough to know
  ## it is a `SightComponent` and not enough to know **which** one: telling two
  ## sights apart means reading a member off the object, and every candidate
  ## member name here is a pre-1.0 guess. So this is unverifiable rather than
  ## inexpressible -- a real difference, and not the same as being closed.
  ##
  ## The assumption therefore stands unchanged: in a raid the sight being
  ## queried for sensitivity is the one being aimed through, which is the one
  ## the optic camera is showing, so the answer is the same. It is an
  ## assumption, it is written down rather than left implied, and **nothing
  ## here has ever run against BSG's client**.
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
  var unusable = ""
  if not argsUsable(params, unusable):
    gSensState = "refused: " & describeSig(params, ret) & " -- " & unusable
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
# Effect 4: FirearmController::get_AimingSensitivity
# ---------------------------------------------------------------------------
#
# Upstream's `AimingSensitivityPatch` injects `ref float ____aimingSens` -- the
# instance's private `_aimingSens` field -- and **scales** it. That is the one
# thing a prefix cannot express: a prefix that suppresses never learns what the
# original would have returned, and one that does not suppress cannot change it.
#
# This file used to say so and leave the feature out. It is a postfix now, which
# is exactly the shape the patch always wanted: run the original, take its
# answer, multiply, hand back the product. Note what is *not* needed any more --
# upstream reaches for the private field because Harmony gives it a way to; the
# getter's own return value is the same number, so nothing here has to know the
# field's name on a build nobody has dumped.
#
# `get_AimingSensitivity` is an instance property getter with no declared
# arguments, so its compiled call is `this` plus IL2CPP's trailing
# `MethodInfo*`: two register slots, comfortably inside the four a postfix can
# carry. It returns `System.Single`, which comes back in XMM0 rather than
# through a hidden buffer. Both facts are checked below against the runtime
# rather than assumed, because both are the reasons the host would refuse.
#
# `withArgs = false`, deliberately, on the JSON form below. The handler wants
# the result and nothing else, and that is the difference between about 440 ns
# a call and about 2.4 us (docs/PERF.md). This getter is asked once per aiming
# frame for the local player, so either would be affordable -- but paying for a
# payload nothing reads would be paying for nothing.
#
# The JSON form is the fallback now rather than the shape of this effect; the
# typed one below it is what arms on a revision-4 host. See the note that
# follows it for why the conversion was worth doing on a hook that fires once a
# frame rather than once per bot per frame.

proc onAimingSensitivity(target, payload: string): HookResult =
  gAimSensHits = gAimSensHits + 1
  let r = hookResult(payload)
  if not r.ok:
    # No result in the payload means this is not a postfix payload, which
    # would mean the host had run the handler on the way *in*. Leaving the
    # value alone is the only safe answer: scaling a number that has not been
    # produced yet is worse than not scaling one.
    return keepResult()
  replaceResult($(r.asFloat() * cfgNonOpticSensMulti))

# ---------------------------------------------------------------------------
# ...and the same scaling on the typed path
# ---------------------------------------------------------------------------
#
# `onAimingSensitivity` above is the JSON form and stays, because a host older
# than ABI revision 4 has nothing else. This is the same multiplication written
# against the register frame.
#
# Line for line it is one decision either way: read what the original returned,
# multiply, hand the product back. What is gone is everything around it. The
# JSON form's ~1615 ns (docs/PERF.md's postfix-with-replacement row) is not the
# thunk and it is not the multiply -- it is a host-side string built out of one
# float, a buffer somebody owns, a copy into this mod's heap, a parse, then a
# *second* float formatted back to text and parsed again by the host to become
# the replacement. Two allocator round trips to change a number that was
# already sitting in XMM0. `resultFloat` reads that register and
# `setResultFloat` writes the slot the thunk moves back into it. The mechanism
# is 38 ns on `tools/perfbench.nim`; from inside a mod DLL, where every frame
# accessor is an ordinary call rather than an inlined load, this handler's two
# reads measure 44 ns -- and it was checked end to end rather than assumed:
# 4.0 through a stand-in method that multiplies by 1.5 comes back as 6.0 with
# the multiplier at 1.0 and as 12.0 with it at 2.0, which requires both that
# the original ran and that the replacement stuck.
#
# **Why convert a hook that fires once a frame at all.** This getter is asked
# for the local player while aiming, so ~1.6 us a frame is 0.01 percent of a
# 60 fps budget and the JSON form was never a stutter -- this conversion is not
# the frame-tax argument `mods/sain` makes. It is worth doing for two smaller
# reasons that are still real. The saving is 1.6 us of *allocator* traffic per
# aiming frame, which is the kind of cost that does not show up as a frame time
# and does show up as a hitch when the heap is busy. And the typed path is the
# one that cannot be wrong about which register the float is in: the JSON form
# formats a `System.Single` through a decimal string, and `$` on a float
# followed by a parse is a round trip this file does not otherwise make on a
# per-frame path.
#
# `retKindOf` is not checked here. `armAimingSensitivity` already asked the
# runtime for the declared return type and refused anything but
# `System.Single`, and `setResultFloat` refuses on its own if the host
# classified it differently -- which is the belt to that braces, and is why the
# `frameReplace()` below is guarded on the setter's answer rather than assumed.

proc onAimingSensitivityTyped(f: PatchFrame): TypedResult =
  let measuring = gAimSensSamples < CostSamples
  var t0 = 0'i64
  if measuring: t0 = perfCounter()
  gAimSensHits = gAimSensHits + 1
  var ok = false
  let v = f.resultFloat(ok)
  if not ok:
    # Either this is a prefix frame -- which would mean the host ran the
    # handler on the way *in*, and the original has not produced a number to
    # scale -- or the declared return is not a float after all. Leaving the
    # value alone is the only safe answer in both cases.
    return frameContinue()
  if not f.setResultFloat(v * cfgNonOpticSensMulti):
    # The setter refused, so the caller would get whatever the original left in
    # the register. Saying `frameReplace()` anyway would hand back that
    # residue; not saying it hands back the unscaled sensitivity, which is the
    # game's own behaviour and is the correct failure.
    return frameContinue()
  if measuring:
    gAimSensNs = gAimSensNs + nanosBetween(t0, perfCounter())
    gAimSensSamples = gAimSensSamples + 1
  frameReplace()

proc aimSensCostNs(): int64 =
  ## The measured cost of one scaling, in nanoseconds, or -1 when nothing was
  ## measured. Reported rather than asserted, for the reason `fovCostNs` gives:
  ## docs/PERF.md's numbers are a stand-in runtime on one machine and this is
  ## the client the mod is actually in.
  if gAimSensSamples <= 0:
    return -1'i64
  result = gAimSensNs div int64(gAimSensSamples)

proc armAimingSensitivity() =
  if not cfgChangeMouseSensitivity:
    gAimSensState = "off (changeMouseSensitivity is false)"
    return
  var params: seq[string] = @[]
  var ret = ""
  if not signatureOf(TyFirearm, "get_AimingSensitivity", -1, params, ret):
    gAimSensState = "refused: no " & TyFirearm & "::get_AimingSensitivity"
    return
  if ret != "System.Single":
    # A postfix on a wider value-type return is refused by the host anyway;
    # refusing here as well means the message names the *mod's* assumption
    # rather than the engine's constraint, which is the more useful one.
    gAimSensState = "refused: it is " & describeSig(params, ret) &
                    " and this scales a float"
    return
  if params.len != 0:
    gAimSensState = "refused: it is " & describeSig(params, ret) &
                    " and a property getter should take none; the name is " &
                    "probably stale on this build"
    return
  # The typed form when the host has it, and the JSON one when it does not.
  #
  # Not "typed or nothing": a host at revision 3 can still run this effect, and
  # 1.6 us once per aiming frame is a real cost rather than a disqualifying
  # one. Which form armed goes in the state line rather than being implied,
  # because the two are thirty-six-fold apart and a log that says only "armed"
  # cannot be used to tell them apart afterwards.
  if typedPatchesReady() and
     hookReturnTyped(TyFirearm & "::get_AimingSensitivity",
                     onAimingSensitivityTyped) == Ok:
    gAimSensTyped = true
    gAimSensState = "armed on the typed path, scaling the original's result " &
                    "by " & $cfgNonOpticSensMulti
  elif hookReturn(TyFirearm & "::get_AimingSensitivity", onAimingSensitivity,
                  withArgs = false) == Ok:
    gAimSensState = "armed on the JSON path (this host is ABI revision " &
                    $hostApiSize() & " bytes of HostApi, and the typed frame " &
                    "wants revision 4), scaling the original's result by " &
                    $cfgNonOpticSensMulti & " at about 1.6 us a call"
  else:
    # The host refuses a postfix on two shapes -- a value-type return wider
    # than a register, and a compiled call needing more than four register
    # slots -- and says which. Neither should apply to a float getter, so if
    # one does, the name resolved to something other than the property.
    gAimSensState = "refused: " & lastError()

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

proc countOnly(target, why: string) =
  ## Count a target whose detour some *effect* already installed.
  ##
  ## `onWatched` increments by name, so a target registered here is counted by
  ## the hook already on it. Two calls to `hook` on one compiled method would
  ## be a detour of a detour; this is how a target is both an effect and a
  ## measurement without being patched twice.
  gWatchNames.add target
  gWatchCounts.add 0

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
  countOnly(target, why)
  if hook(target, onWatched) == Ok:
    info "watching " & target & " (" & why & ")"
  else:
    warn "cannot watch " & target & ": " & lastError()
    shrink(gWatchNames, gWatchNames.len - 1)
    shrink(gWatchCounts, gWatchCounts.len - 1)

# ---------------------------------------------------------------------------
# What drives the FOV write, and why it is no longer `verifyHooks`
# ---------------------------------------------------------------------------
#
# The per-frame FOV write is the effect this mod exists for, and until now it
# was installed by the *diagnostic* block: it rode on the `FrameDriver` detour,
# that detour was only attached when `verifyHooks` was true, and setting
# `verifyHooks` to false in config.json therefore switched off the mod. The log
# warned about it, which is better than silence and is not a defence -- a
# diagnostic flag that disables the feature is a bug whatever it prints. The
# driver is armed on its own account now, and `verifyHooks` decides only what
# is counted.
#
# Two drivers, in order of how well each is established:
#
#  1. **The `EFT.Player::Look` detour.** A game method, so the game's thread by
#     construction. Fires once per *player* per frame, bots included, which is
#     why the write is rate-limited to ~250 Hz.
#
#  2. **`everyMain`, when the first cannot be installed** -- when `Look` was
#     renamed, inlined, or is already carrying another mod's patch. It fires
#     once per host drain, which is once per frame, and holds one scheduler
#     slot rather than one per firing. Gated on the host's own answer:
#     `call("aowlspt.host::main_thread")` reports `bound` only once the drain
#     has actually *fired* on Unity's thread, and a camera write from the
#     host's own thread is the documented way to crash a frame or two later.
#     Not bound is a refusal, not a fallback.
#
# The rate gate stays on either path. On `everyMain` it will almost never trip
# -- one firing a frame at 240 fps is already under the interval -- and leaving
# it in costs one `perfCounter` per frame and keeps one code path rather than
# two.

type
  MainThread = object
    ok: bool           ## the host answered at all
    bound: bool        ## the drain is on Unity's thread and has fired
    methodName: string
    frames: int64

proc askMainThread(): MainThread =
  ## `call("aowlspt.host::main_thread")`, decoded. The host answers it before
  ## it checks whether the runtime is up, so it is meaningful even with no
  ## game -- which is what makes it usable as a gate.
  result = MainThread(ok: false, bound: false, methodName: "", frames: 0'i64)
  var raw = ""
  let empty = "[]"
  if call("aowlspt.host::main_thread", empty, raw) != Ok:
    return
  if raw.len == 0:
    return
  result.ok = true
  result.bound = asBool(field(raw, "bound"), false)
  result.methodName = asText(field(raw, "method"), "")
  result.frames = int64(asInt(field(raw, "frames"), 0))

var gDriverState = "not attempted"
var gDriverIsEveryMain = false
var gDriverThreadId = 0'i64
var gDriverFirings = 0

proc onFovTick(payload: string): string =
  ## The `everyMain` driver. One firing per drain.
  ##
  ## The thread id is recorded rather than assumed: the whole claim behind this
  ## path is "this ran where a Unity write is legal", and the number is the
  ## only evidence for it available from inside a mod. It is printed next to
  ## the host's own answer so the two can disagree in public.
  gDriverFirings = gDriverFirings + 1
  gDriverThreadId = currentThreadId()
  applyFov()
  result = ""

proc armFovDriver() =
  ## Install whatever will call `applyFov` every frame.
  if not bWorld.ok or not bCamInstance.ok or
     gFovState.substr(0, 5) != "arming":
    # The statics, *and* the SetFov arity check that follows them. A driver
    # armed over a refused chain is a per-frame call that returns at its first
    # guard for the rest of the session, and a log line saying the write is
    # driven.
    gDriverState = "refused: the FOV chain did not arm (" & gFovState &
                   "), so a driver would run a chain that refuses per frame"
    return
  if hook(FrameDriver, onWatched) == Ok:
    gDriverState = "armed on the " & FrameDriver & " detour, which is a game " &
                   "method and therefore the game's own thread"
    return
  let hookWhy = lastError()
  let mt = askMainThread()
  if not mt.ok:
    gDriverState = "refused: " & FrameDriver & " could not be detoured (" &
                   hookWhy & ") and this host does not answer " &
                   "aowlspt.host::main_thread, so there is no thread " &
                   "everyMain could be shown to reach"
    return
  if not mt.bound:
    gDriverState = "refused: " & FrameDriver & " could not be detoured (" &
                   hookWhy & ") and the host's main-thread drain is not " &
                   "confirmed on Unity's thread (" &
                   (if mt.methodName.len > 0: "drain method " & mt.methodName &
                                              ", " & $mt.frames & " firings"
                    else: "no drain method bound") &
                   "), so everyMain would set a camera's field of view from " &
                   "the host's own thread"
    return
  if everyMain(onFovTick) == Ok:
    gDriverIsEveryMain = true
    gDriverState = "armed on everyMain (" & FrameDriver &
                   " could not be detoured: " & hookWhy & "), which the host " &
                   "drains from " & mt.methodName & " on Unity's thread -- " &
                   "once per frame rather than once per player per frame"
  else:
    gDriverState = "refused: " & FrameDriver & " could not be detoured (" &
                   hookWhy & ") and everyMain was refused by the host too"

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
    gAimSensState = gFovState
    warn "FOV Fix: " & gFovState
  else:
    discard bindFovStatics()
    armScaleFix()
    armScopeSensitivity()
    armAimingSensitivity()

  # The driver goes in before the diagnostics, because it is the effect and
  # they are the measurement. It used to go in after, inside the `verifyHooks`
  # block, which meant one config flag switched off the mod.
  armFovDriver()

  info "FOV Fix: per-frame FOV write -- " & gFovState
  info "FOV Fix:   driven by -- " & gDriverState
  info "FOV Fix: CalculateScaleValueByFov -- " & gScaleState
  info "FOV Fix: scope sensitivity -- " & gSensState
  info "FOV Fix: aiming sensitivity -- " & gAimSensState

  if not cfgVerifyHooks:
    info "verifyHooks is off; not attaching the target-verification detours. " &
         "The FOV write is unaffected -- it is driven on its own account now, " &
         "and this flag decides only what is counted."
    return

  # The exact methods the original patched, in the original's order. Sixteen
  # patch slots exist; this uses six, two of which now do work rather than
  # only counting.
  watch("EFT.Animations.ProceduralWeaponAnimation::UpdateWeaponVariables",
        "PwaWeaponParamsPatch -- where upstream learns the current weapon")
  watch("EFT.Animations.ProceduralWeaponAnimation::LerpCamera",
        "LerpCameraPatch -- not ported: the camera-offset field names cannot " &
        "be confirmed against a running build. The cost objection this line " &
        "used to carry (\"reaching `this` costs ~1 us per frame\") expired " &
        "with ABI revision 3")
  # Counted, not hooked again: `armFovDriver` already detoured this when it
  # took the first of its two paths, and on the `everyMain` path there is no
  # detour on it to count.
  if gDriverIsEveryMain:
    info "not watching " & FrameDriver &
         " -- it could not be detoured, which is why the write is on everyMain"
  elif armed(gDriverState):
    countOnly(FrameDriver,
              "FreeLookPatch -- not ported; carries the per-frame FOV write")
    info "watching " & FrameDriver & " through the driving hook (the FOV write)"
  else:
    watch(FrameDriver,
          "FreeLookPatch -- not ported, and not carrying the FOV write " &
          "either: " & gDriverState)
  # An effect that already hooked its target is its own watcher: `hookArgs`
  # and `hook` both go through `patch`, and two patches on one compiled
  # function would be a detour of a detour.
  if armed(gScaleState):
    info "watching EFT.Player::CalculateScaleValueByFov through the " &
         "replacing hook (CalculateScaleValueByFovPatch)"
  else:
    watch("EFT.Player::CalculateScaleValueByFov",
          "CalculateScaleValueByFovPatch -- viewmodel/ribcage scale")
  if armed(gAimSensState):
    info "watching EFT.Player.FirearmController::get_AimingSensitivity " &
         "through the scaling postfix (AimingSensitivityPatch)"
  else:
    watch("EFT.Player.FirearmController::get_AimingSensitivity",
          "AimingSensitivityPatch -- aim sensitivity, scaled")
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
  info "    driven by " & gDriverState
  if gDriverIsEveryMain:
    if gDriverFirings > 0:
      info "    (everyMain fired " & $gDriverFirings & " times, on thread " &
           $gDriverThreadId & " -- compare that with the drain thread in " &
           "aowlspt.host::main_thread; a mismatch would mean the write is " &
           "not where this mod claims it is)"
    else:
      warn "    (everyMain armed and never fired: the host queued it and its " &
           "drain has not run, so nothing has been written at all)"
  let ns = fovCostNs()
  if ns >= 0'i64:
    info "    (measured " & $ns & " ns per applied write over " & $gFovSamples &
         " of them, on this client's own clock -- docs/PERF.md's numbers are " &
         "from a stand-in runtime and are not this)"
  else:
    info "    (no cost measured: no write ever applied, so there was " &
         "nothing to time)"
  reportEffect("CalculateScaleValueByFov", gScaleState, gScaleHits)
  reportEffect("scope sensitivity", gSensState, gSensHits)
  reportEffect("aiming sensitivity", gAimSensState, gAimSensHits)
  if armed(gAimSensState):
    let ans = aimSensCostNs()
    let path = (if gAimSensTyped: "typed" else: "JSON")
    if ans >= 0'i64:
      info "    (measured " & $ans & " ns per scaling over " &
           $gAimSensSamples & " of them on the " & path & " path, on this " &
           "client's own clock -- docs/PERF.md's numbers are from a stand-in " &
           "runtime and are not this)"
    elif gAimSensTyped:
      info "    (armed on the typed path; nothing measured, because the " &
           "getter was never called on this build -- there was no scaling to " &
           "time)"
    else:
      info "    (armed on the JSON path, which is not timed in place: the " &
           "measurement is on the typed handler, and this host does not have " &
           "it)"
  info "  not ported, and why -- each of these was re-checked against what " &
       "the host does today rather than what it did when the port was " &
       "written: LerpCamera and Look are neither a gap nor a cost any more " &
       "(the payload carries `this`, thisPointer turns it into an address in " &
       "8 ns, and bindRaw reaches a Vector3) -- what is left is that this " &
       "port cannot confirm the camera-offset field names on " &
       "ProceduralWeaponAnimation against a running build, which is a name " &
       "problem rather than a capability one; the FOV slider range is the " &
       "same kind of name problem on GameSettingsTab; the toggle-zoom key " &
       "needs a KeyCode ordinal this port will not guess -- and note that " &
       "that is now the whole of the objection, because an enum argument is " &
       "a plain number to the host and no longer refused. " &
       "get_AimingSensitivity is no longer on this list: it is a postfix now, " &
       "typed where the host allows it. See the module comment."

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------
#
#     aowl run mods/fov                      # --side sim
#
# What this can and cannot establish, said before the output rather than after.
#
# **It cannot bind against Tarkov.** `aowlspt-sim` is a managed host with no
# `GameAssembly.dll` in the process, so `openIl2Cpp()` correctly finds nothing
# and every binding refuses with that reason. That is the expected result and it
# is still worth printing, because the shape of the report -- one line per
# member, naming the member and the reason -- is the shape the client half
# prints in a raid, and a reader who has seen it here knows how to read it
# there.
#
# **It can bind against a runtime you point it at.** `selfTestRuntime` in
# config.json is a path to any `GameAssembly.dll` -- `tests/mockil2cpp`'s
# stand-in, or a real client's from a copy of the install. Out of process the
# runtime is loaded but not started, so `il2cpp_init` is called; on a real
# client that will very likely refuse, because the metadata is decrypted during
# the game's own startup. A refusal there is a real answer and is printed as one.
#
# **It checks the arithmetic that needs no game at all.** The
# magnification->sensitivity table is pure config, and a table that is not
# monotonic in magnification is a config error this catches without a raid.
#
# **It measures the per-frame path either way.** `applyFov` is called in a loop
# and timed on `perfCounter`, the same clock the bindings report their own cost
# on. With nothing bound that measures the guard, which is the floor the effect
# costs when it is switched off.

proc reportBinding(label: string; b: Binding) =
  if b.ok:
    success "  fast     " & label & " -- " & b.why & " (bind " & $b.bindNs &
            " ns)"
  else:
    warn "  REFUSED  " & label & " -- " & b.why

proc probeMember(owner, member: string; argc: int) =
  ## The name half of a member that is only ever *bound* against a live object.
  ##
  ## Deliberately not a binding. `get_ProceduralWeaponAnimation` is bound at
  ## runtime against the class the player object actually is, which may be a
  ## subclass this file cannot name -- so what a name check can honestly say is
  ## "the type exists and declares a member of this name and arity, and here is
  ## the signature the runtime reports". A subclass override does not show up
  ## here at all, and saying so is the point.
  var params: seq[string] = @[]
  var ret = ""
  if signatureOf(owner, member, argc, params, ret):
    info "  name ok  " & owner & "::" & member & " " & describeSig(params, ret) &
         " -- bound at runtime against the object's own class"
  else:
    warn "  NO NAME  " & owner & "::" & member & "/" & $argc &
         " is not declared on that type (a subclass may still declare it; " &
         "the runtime binding is the one that decides)"

proc checkSensTable(): int =
  ## More magnification must never mean more sensitivity. A config with two
  ## multipliers the wrong way round produces a scope that gets twitchier as it
  ## zooms in, which is exactly the bug this table exists to remove -- and it is
  ## decidable here, with no game.
  result = 0
  var fovs: seq[float] = @[]
  fovs.add 60.0    # unmagnified
  fovs.add 40.0    # 1x
  fovs.add 20.0    # 2x
  fovs.add 13.0    # 3x
  fovs.add 10.0    # 4x
  fovs.add 8.0     # 5x
  fovs.add 6.0     # 6x
  fovs.add 4.5     # 8x
  fovs.add 3.5     # 10x
  fovs.add 2.5     # 12x
  fovs.add 1.0     # beyond
  var prev = zoomSensFor(fovs[0])
  for i in 1 ..< fovs.len:
    let cur = zoomSensFor(fovs[i])
    if cur > prev:
      error "  sensitivity rises with magnification at " & $fovs[i] &
            " degrees (" & $prev & " -> " & $cur & "); check config.json"
      inc result
    prev = cur

# ---------------------------------------------------------------------------
# The two guards, exercised rather than described
# ---------------------------------------------------------------------------
#
# Both were rewritten today and one of them *could not fail* before:
# `classifyType` answered `fkPtr` for every resolvable non-primitive, so
# `argsUsable`'s `== fkNone` test was false for every real EFT type and its
# body never ran. A guard nobody has watched refuse is a guard nobody has
# tested, and describing one in a comment is not the same as watching it work.
#
# `tests/mockil2cpp` carries the shapes, and not by accident:
#
#   * `UnityEngine.Vector3` is a 12-byte value type -- the same shape as the
#     `UnityEngine.Vector2` that is the whole reason `Player::Look` is not
#     ported. If the placeholder gate cannot refuse the first, its refusal of
#     the second is a coincidence rather than a mechanism.
#   * `EFT.GameWorld::get_MainPlayer` returns a reference, so stating that it
#     returns a float is exactly the mistake `bindOnObject` cannot catch on its
#     own -- and the mistake that produces a plausible number rather than a
#     crash.
#
# With no `selfTestRuntime` there is no runtime to ask and every check reports
# "not checked" rather than passing. That distinction is the point: a check
# that passes because the thing it checks never happened is worse than no
# check, and this is the file that says so about everything else.

proc guardOk(what: string) =
  success "  guard ok " & what

proc guardBad(what: string) =
  error "  GUARD    " & what

proc checkGuards(): int =
  ## How many guards answered wrongly. Zero on a runtime that has the shapes;
  ## zero and a warning on one that does not.
  result = 0
  if not rtOpen:
    warn "  guards not checked: no runtime is bound, so there is nothing to " &
         "ask. Set selfTestRuntime to exercise them."
    return

  # --- 1. the placeholder gate, which could not fail until today ------------
  var why = ""
  var wide: seq[string] = @[]
  wide.add "UnityEngine.Vector3"
  if findClass(rt, "UnityEngine.Vector3") == nil:
    warn "  guard skipped: this runtime has no UnityEngine.Vector3, so the " &
         "placeholder gate has nothing wide to refuse"
  elif argsUsable(wide, why):
    guardBad "argsUsable accepted a UnityEngine.Vector3 parameter. The host " &
             "reports one as {\"valueType\":\"...\"}, so a hook reading it " &
             "would read a placeholder -- which is the reason Player::Look " &
             "is refused, and it would stop being a reason. This is the " &
             "answer the old classInstanceSize > 24 test gave on a runtime " &
             "that reports payload sizes."
    inc result
  else:
    guardOk "argsUsable refuses a UnityEngine.Vector3 parameter -- " & why

  var narrow: seq[string] = @[]
  narrow.add "System.Single"
  narrow.add "System.Boolean"
  why = ""
  if not argsUsable(narrow, why):
    guardBad "argsUsable refused (Single, Boolean), which is SetFov's own " &
             "parameter list: " & why
    inc result
  else:
    guardOk "argsUsable accepts (System.Single, System.Boolean)"

  # --- 2. the stated-kinds check on ensureCall ------------------------------
  #
  # Every call in the FOV chain states its register classes, because
  # `bindOnObject` cannot infer them. An assertion nobody checks is a
  # remembered signature.
  let bw = bindMethod(rt, TyGameWorld, "get_Instance", 0)
  var w = nullPtr()
  if bw.ok:
    var a = noArgs()
    w = callPtr(bw, nullPtr(), a)
  if w == nil:
    warn "  guard skipped: no live " & TyGameWorld & " on this runtime, so " &
         "the stated-kinds check has nothing to disagree with"
  else:
    var none = noKinds()
    var right = noObjBind()
    if not ensureCall(right, w, "get_MainPlayer", none, fkPtr):
      guardBad "ensureCall refused get_MainPlayer stated correctly as " &
               "returning a reference: " & right.why
      inc result
    else:
      guardOk "ensureCall accepts get_MainPlayer stated as returning a " &
              "reference"
    var wrong = noObjBind()
    if ensureCall(wrong, w, "get_MainPlayer", none, fkF32):
      guardBad "ensureCall accepted get_MainPlayer stated as returning a " &
               "float. The address would be read out of XMM0, which holds " &
               "whatever the last floating-point operation left there -- a " &
               "number, not a crash."
      inc result
    else:
      guardOk "ensureCall refuses get_MainPlayer stated as returning a " &
              "float -- " & wrong.why

proc simSelfTest(): Status =
  info "FOV Fix self-test (--side sim)"

  # --- the arithmetic, which needs no game.
  let bad = checkSensTable()
  if bad == 0:
    success "  the magnification->sensitivity table is monotonic across 11 " &
            "magnifications (unmagnified x" & $zoomSensFor(60.0) & ", 4x x" &
            $zoomSensFor(10.0) & ", 12x x" & $zoomSensFor(3.0) & ")"
  else:
    error "  " & $bad & " inversion(s) in the sensitivity table"
    return ErrGeneric

  # --- the client half.
  let wanted = selfTestRuntime(cfgText("selfTestRuntime", ""))
  if wanted.refusal.len > 0:
    warn "  " & wanted.refusal
  let runtimePath = wanted.path
  if runtimePath.len > 0:
    rt = openIl2Cpp(runtimePath)
    if not rt.loaded:
      warn "  selfTestRuntime " & runtimePath & " could not be loaded " &
           "(error " & $rt.lastError & "); falling back to the process"
    else:
      rtOpen = true
      let wantedDd = selfTestDataDir(cfgText("selfTestDataDir", ""))
      if wantedDd.refusal.len > 0:
        warn "  " & wantedDd.refusal
      if wantedDd.path.len > 0:
        rt.setDataDir(wantedDd.path)
      if rt.init("aowl-fovfix-selftest") == nil:
        warn "  " & runtimePath & " loaded but il2cpp_init returned no " &
             "domain, so it has no type universe to search. That is the " &
             "expected answer for a real client out of process -- the " &
             "metadata is decrypted during the game's own startup -- and " &
             "every binding below will refuse with 'no such type'."
      else:
        info "  bound and started " & runtimePath & " for the binding report"
  if not rtOpen:
    if not openRuntime():
      warn "  no IL2CPP runtime in this process -- aowlspt-sim is a managed " &
           "host and GameAssembly.dll is not loaded. Every binding below " &
           "will refuse for that reason, which is the correct answer here. " &
           "Set AOWLSPT_SELFTEST_RUNTIME, or \"selfTestRuntime\" in " &
           "config.json, to an ABSOLUTE path to a GameAssembly.dll to get a " &
           "real report offline; `aowl run` sets it to the stand-in runtime."

  info "  bindings, in the order the frame path takes them:"
  discard bindFovStatics()
  reportBinding("GameWorld::get_Instance (static, by name)", bWorld)
  probeMember(TyGameWorld, "get_MainPlayer", 0)
  probeMember(TyPlayer, "get_ProceduralWeaponAnimation", 0)
  reportBinding("CameraManager::get_Instance (static, by name)", bCamInstance)
  probeMember(TyCamera, "get_Camera", 0)
  probeMember(TyUnityCamera, "get_fieldOfView", 0)
  # -1 when the arity check above did not settle on one, so the probe reports
  # whatever `SetFov` actually is rather than asking about an arity of zero.
  probeMember(TyCamera, "SetFov", (if gSetFovArgc > 0: gSetFovArgc else: -1))
  probeMember(TyPwa, "get_IsAiming", 0)
  probeMember(TyPwa, "get_CurrentScope", 0)
  info "    get_IsOptic -- no name to probe: it lives on the class the scope " &
       "object turns out to be, which is not CurrentScope's declared type. " &
       "Bound against the object, and only in a raid."

  info "  the optic camera, for the sensitivity table:"
  if bindOpticCamera():
    reportBinding("optic container get_Instance", bOpticInstance)
  else:
    warn "  REFUSED  optic camera -- " & gOpticChainState

  info "  the two replacing hooks (installed only in a raid, and only when " &
       "the runtime confirms the signature):"
  var params: seq[string] = @[]
  var ret = ""
  if signatureOf(TyPlayer, "CalculateScaleValueByFov", -1, params, ret):
    info "  name ok  " & TyPlayer & "::CalculateScaleValueByFov " &
         describeSig(params, ret) & (if ret == "System.Single":
           " -- a float return, which stopWith can replace" else:
           " -- NOT a float return; this port would refuse it")
  else:
    warn "  NO NAME  " & TyPlayer & "::CalculateScaleValueByFov"
  if signatureOf(TySight, "get_GetCurrentSensitivity", -1, params, ret):
    info "  name ok  " & TySight & "::get_GetCurrentSensitivity " &
         describeSig(params, ret)
  else:
    warn "  NO NAME  " & TySight & "::get_GetCurrentSensitivity"

  info "  the guards, exercised rather than described:"
  let badGuards = checkGuards()
  if badGuards > 0:
    error "  " & $badGuards & " guard(s) answered wrongly; every one of them " &
          "is a wrong number written to a camera rather than a refusal"
    return ErrGeneric

  info "  refusals that remain, with the reason each one actually has:"
  # These three lines were stale, and the third was flatly contradicted by the
  # code above it. `aowl run` was printing "get_AimingSensitivity is not
  # ported" for an effect that has been a postfix -- typed, where the host
  # allows it -- for a while, and was still quoting the handle-to-pointer cost
  # that ABI revision 3 removed. A stale refusal is worse than no refusal: it
  # is the file disagreeing with itself in the one place a reader goes to find
  # out what is missing.
  info "    LerpCamera -- a *name*, not a cost and not a capability. Both " &
       "old blockers are gone: the payload carries `this`, thisPointer turns " &
       "it into an address in ~8 ns, and bindRaw binds a method by its native " &
       "slot shape, which is what a 12-byte Vector3 by hidden pointer needs. " &
       "What is left is that this port cannot confirm the camera-offset " &
       "field names on ProceduralWeaponAnimation against a running build, " &
       "and will not write a camera offset through a guessed name."
  info "    Player::Look -- unchanged, and about the payload rather than the " &
       "instance: the angles arrive as a UnityEngine.Vector2, which is passed " &
       "by hidden pointer and reported as {\"valueType\":\"...\"} -- named " &
       "and refused rather than invented -- so there is nothing in the " &
       "payload to clamp. A postfix does not help; Look returns void."
  info "    get_AimingSensitivity -- **ported**, and no longer a refusal at " &
       "all. It is a postfix on the getter's own result: run the original, " &
       "multiply, hand the product back. Typed (~44 ns) on a revision-4 " &
       "host, JSON (~1.6 us) on revision 3, and the effect's state line says " &
       "which armed."
  info "    the toggle-zoom key -- UnityEngine.Input::GetKey takes a KeyCode " &
       "enum and this port will not map the configured names onto ordinals " &
       "it cannot confirm."
  info "    the base-FOV slider range -- now blocked only by a *name*. The " &
       "instance is delivered and this fires when a menu opens, so the cost " &
       "objection does not apply; what cannot be confirmed from here is which " &
       "field on GameSettingsTab holds the slider bounds."

  # --- the cost of the per-frame path, on this machine's own clock.
  const Iterations = 20000
  gLastFovTicks = 0'i64
  let t0 = perfCounter()
  var i = 0
  while i < Iterations:
    # The rate gate would skip all but the first of these, which would measure
    # the gate rather than the path. Clearing it each time measures the path.
    gLastFovTicks = 0'i64
    applyFov()
    inc i
  let per = nanosBetween(t0, perfCounter()) div int64(Iterations)
  if gFovWrites > 0:
    success "  per-frame cost " & $per & " ns over " & $Iterations &
            " calls, " & $gFovWrites & " of which wrote"
  else:
    info "  per-frame cost " & $per & " ns over " & $Iterations &
         " calls, none of which reached a write (no world). That is the " &
         "guard: what the effect costs when there is nothing to do."
  info "  for comparison, docs/PERF.md measures one boxed host call at " &
       "950-1235 ns and one bound call at 6-10 ns; the eight-call chain this " &
       "replaces was about 8 us of marshalling per frame"
  result = Ok

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

var gElapsedMs = 0'i64

proc onLoad(): Status =
  loadConfig()
  declareSettings(fovSchema())
  discard serve("/aowlspt/settings/" & ModGuid, onFovSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onFovSettingsReset)
  success ModName & " " & ModVersion & " loaded on " & hostName()
  if side() == sideSim:
    return simSelfTest()
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
