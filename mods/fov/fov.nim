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
## Four effects are implemented (the fourth, `get_AimingSensitivity`, is
## described under "WHAT IS STILL NOT EXPRESSIBLE" below only because that is
## where its refusal used to live), each one armed only when every binding it
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
##   the rest of this file refuses.
##
##   **That last sentence has now expired too, and the replacement is narrower.**
##   `tools/fldoff.py fields EFT.Animations.ProceduralWeaponAnimation` prints the
##   whole field list off `GameAssembly.dll` + the decrypted metadata, so the
##   names are no longer unconfirmable: `_cameraByFOVOffset` (Vector3 @0x1e0),
##   `RotationCameraOffset` (Vector3 @0x18c), `_vCameraTarget` (Vector3 @0x180),
##   `Offset` (Vector3 @0x98), `CameraSmoothTime` (float @0x124), `vel`
##   (Vector3 @0x128) all exist and all have offsets. What blocks the port is
##   one step further in: upstream's `LerpCameraPatch` is **not vendored beside
##   this file** (`mods/fov/` holds LICENSE.txt, README.md, config.json and this
##   source, and nothing of Fontaine's own code), so which of those six it
##   writes, in what order, and against which speed, is a guess about
##   *behaviour* rather than about a *name*. That is a strictly worse thing to
##   guess, so it stays refused -- but the fix is now "vendor or read the
##   upstream patch", not "dump a build".
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
## * **The toggle-zoom key -- NOW WIRED.** `zoomToggleKey`, `holdToZoom` and
##   the three `*ToggleZoomMulti` settings need to know whether a key is down.
##   For months they could not, and the reason recorded here was half expired
##   and half a tool bug. Both halves are worth keeping straight.
##
##   The expired half: an enum argument used to be refused outright by the
##   host as something it "cannot build from a JSON scalar". That is gone --
##   an enum is a number in both directions now (docs/IL2CPP.md).
##
##   The wrong half: this file then said the name->ordinal map "cannot be
##   derived here", and cited a MEASUREMENT as proof -- `KeyCode.None` reading
##   back as **-25161728** and `KeyCode.Space` as **-2113895872** out of
##   metadata property 8. The measurement was real; the conclusion drawn from
##   it was wrong. Property 8 (`fieldAndParameterDefaultValueData`) is **not
##   encrypted**. It stores I4/U4 as ECMA-335 **compressed integers,
##   big-endian and zigzagged**, not as raw int32 -- so reading four raw bytes
##   at `None` (a single `0x00`) swallowed the next three constants and
##   produced exactly that number. The reader was the bug, not the blob. This
##   is the shape of defect CLAUDE.md 9b names: a check that could only ever
##   agree with itself, dressed as a measurement.
##
##   `tools/fldoff.py enum <Type>` / `enumval <Type> <Member>` and
##   `tools/il2cpp_resolve.py enum` decode it correctly now, and
##   `verify-consts` puts the decoder against 19 independently-known values
##   (KeyCode None/Space/A/Alpha0 plus one per primitive width) before
##   anything is trusted. All 328 `UnityEngine.KeyCode` members come out; the
##   table in this file is that command's verbatim output, not a recollection.
##
##   So: `Input::GetKey(KeyCode)` @0x531EAE0 and `GetKeyDown(KeyCode)`
##   @0x531EB80, both STATIC, both prologue-verified 16/16 at bind, both real
##   bodies in the `il2cpp` section rather than the universal empty-body stub.
##   Each shares its RVA with its `*Int` internal alias, which is a hazard for
##   a detour and not for a call. `pollZoomKey` runs on the game thread ahead
##   of the FOV rate gate -- an edge is one frame wide and that gate skips
##   frames -- under a 500 Hz gate of its own, and its answer multiplies into
##   the same `SetFov` write Effect 1 already makes. See "Effect 5".
##
##   What is still NOT claimed: above 500 fps a toggle press can be missed
##   (`holdToZoom`, the default, reads a level and is unaffected), and
##   `cancelZoomOnUnAds` clears the latch against the PREVIOUS write's aiming
##   state, one frame late.
##
## * **The base-FOV slider range** (`minBaseFov`/`maxBaseFov`) -- upstream's
##   `FovRangePatch` rewrites the slider bounds on a `GameSettingsTab` instance.
##   This file used to say the blocker was naming the slider field on
##   `GameSettingsTab` -- "a much shorter distance to travel".
##
##   **It was measured, and the distance is infinite.** `fldoff.py fields
##   EFT.UI.Settings.GameSettingsTab` lists all 34 fields on this build and
##   there is no FOV bound among them: the type holds `_floatSliderTemplate`,
##   `_toggleTemplate`, `_dropDownTemplate`, `_settingsRoot`, `_gameSettings`
##   and the nickname/wishlist controls, and nothing else. The bounds live one
##   type away, on `EFT.Settings.Game.GameSettingsGroup`, as
##   `MIN_FIELD_OF_VIEW` and `MAX_FIELD_OF_VIEW` -- and both carry
##   `attrs = 0x8056`, i.e. **`FIELD_ATTRIBUTE_LITERAL`**. A C# `const` has no
##   storage at runtime; the compiler has already substituted its value into
##   every use site. There is no field to write, no getter to detour and no
##   instance that holds it. This is not "not expressible yet"; it is not
##   expressible by a field write at all, on this build, and the only route
##   left would be patching each inlined comparison individually. The settings
##   stay `implemented = false` and now say why in terms that can be falsified.
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
  ModName = "FOV"
  # The display author. Upstream attribution lives in this file's header,
  # `mods/fov/README.md` and LICENSE.txt -- not in the user-facing mod list.
  ModAuthor = "aowlspt"
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
var gZoomKeyDirty = true
  ## Raised by `loadConfig`, so the KeyCode ordinal is re-resolved from
  ## `cfgZoomToggleKey` on the next frame. `loadConfig` is declared long
  ## before `keyCodeOrdinal` exists, and this avoids a forward declaration
  ## whose only purpose would be ordering.
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
var cfgEnableFovWrite = false
  ## THE PER-FRAME FOV WRITE ITSELF. DEFAULT OFF.
  ##
  ## Not caution for its own sake. `CameraManager::get_Instance` and
  ## `SetFov` are prologue-verified 16/16 against the installed
  ## GameAssembly.dll, and that proves THE BYTES MATCH. It does not prove
  ## that calling them from the host's `everyMain` drain, at boot, with a
  ## NULL trailing MethodInfo*, is survivable -- and neither has ever
  ## actually been EXECUTED in the client. The 9.703s death is still
  ## unlocalised.
  ##
  ## So the mod loads, verifies, reports honestly, and writes nothing until
  ## somebody turns this on deliberately. A FOV mod that boots and declines
  ## is shippable; one that kills the client is not.
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

var cfgVerifyHooks = false
  ## The target-verification detours. DEFAULT OFF as of the crash fix: every
  ## one of them is `patch(<name>, ...)`, i.e. a by-name host detour, and
  ## they exist purely to COUNT firings. Diagnostics are not worth a risk the
  ## effect itself has been rewritten to avoid. Read from the NEW key
  ## `verifyHooksByName` -- see `loadConfig` for why the old name could not
  ## be reused.

var gStaleVerifyHooks = false
  ## Whether a deployed config.json still carries the retired `verifyHooks`
  ## key. Reported, not obeyed. An orphaned key that silently does nothing is
  ## how the next person loses an afternoon.

var cfgDeferUntilUnityThread = true
  ## Hold every hook until the host says its main-thread drain has fired.
  ## Default ON: the unsafe direction is the one that crashed.

var cfgHookFrameDriver = false
  ## Drive the per-frame write from a detour on EFT.Player::Look instead of
  ## from `everyMain`. DEFAULT OFF -- see `armFovDriver`.

const
  DeferPollMs = 500'i64
    ## How often to ask the host. The answer changes at most once per run.
  DeferGiveUpMs = 180_000'i64
    ## After this, refuse rather than arm. A surviving run confirmed the drain
    ## at 14.469s, so three minutes is not a tight bound -- it is the point at
    ## which "it is coming" stops being credible.

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
  gZoomKeyDirty = true
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
  cfgEnableFovWrite = cfgBool("enableFovWrite", false)
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

  # RENAMED, and the rename IS the fix.
  #
  # MEASURED 2026-08-26: the client died at 8.328s with the breadcrumb trail
  # ending at E1 and no E2 -- because E2 sits on the `if not cfgVerifyHooks`
  # branch and that branch was NOT TAKEN. The deployed
  # D:\Aowlsptowlspt\modsov\config.json still carries
  # `"verifyHooks": true` from before this key's default was flipped, only
  # fov.dll was staged, and a default is not a value -- `cfgBool` reads the
  # file. So the gate was real and could not take effect, and execution fell
  # through into the `watch(...)` calls, every one of which is `patch(<name>,
  # ...)`: a BY-NAME host detour, the last by-name route in the mod.
  #
  # Flipping a default cannot fix that, because the stale file wins. Reading
  # a NEW key can: `verifyHooksByName` does not exist in any deployed
  # config.json, so it can only ever take the default below until somebody
  # writes it deliberately. `verifyHooks` is deliberately no longer read at
  # all -- see `gStaleVerifyHooks`, which reports the orphaned key rather
  # than silently ignoring it.
  cfgVerifyHooks = cfgBool("verifyHooksByName", false)
  gStaleVerifyHooks = cfgBool("verifyHooks", false)
  cfgDeferUntilUnityThread = cfgBool("deferUntilUnityThread", true)
  # Default OFF. See `armFovDriver` for why: it is the only remaining
  # by-name route on the client path, and its target's sharedness is
  # unchecked.
  cfgHookFrameDriver = cfgBool("hookFrameDriver", false)

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
               description = "Read only. MEASURED: the bound is the C# const " &
                 "GameSettingsGroup.MAX_FIELD_OF_VIEW (field attrs 0x8056 = " &
                 "LITERAL|STATIC|HASDEFAULT). A const has no storage and is " &
                 "inlined at every use site, so there is nothing to write."),
    intSetting("minBaseFov", "Min base FOV", 30, lo = 10, hi = 120,
               category = "FOV", implemented = false,
               description = "Read only. MEASURED: MIN_FIELD_OF_VIEW is a C# " &
                 "const (attrs 0x8056), same as the max -- inlined, no storage."),

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
                   category = "Toggle zoom",
                   description = "Applies the toggle-zoom FOV multipliers " &
                     "while this key asks for zoom. The name is resolved to a " &
                     "UnityEngine.KeyCode ordinal from a 328-member table " &
                     "generated by `tools/fldoff.py enum UnityEngine.KeyCode`, " &
                     "then passed to Input::GetKey / GetKeyDown at their " &
                     "prologue-verified static RVAs. A name that is not a " &
                     "KeyCode member is REFUSED with the name printed -- it is " &
                     "never quietly read as KeyCode.None, which is a real key " &
                     "whose ordinal is 0."),
    boolSetting("holdToZoom", "Hold to zoom", true, category = "Toggle zoom",
                description = "On: zoom lasts while the key is held " &
                  "(Input::GetKey, a level). Off: each press toggles it " &
                  "(Input::GetKeyDown, an edge, latched in this mod). Both " &
                  "are polled ahead of the FOV rate gate, because an edge is " &
                  "one frame wide and that gate skips frames."),

    floatSetting("rifleCameraZOffset", "Rifle camera Z offset", 0.025,
                 lo = -0.2, hi = 0.2, step = 0.005, category = "Camera",
                 implemented = false,
                 description = "Read only. ProceduralWeaponAnimation's field " &
                   "list IS now resolvable offline (tools/fldoff.py), so the " &
                   "old 'cannot confirm the name' reason has expired. What " &
                   "blocks it now is semantics: upstream's LerpCameraPatch is " &
                   "not vendored beside this file, so WHICH of _cameraByFOVOffset " &
                   "/ RotationCameraOffset / _vCameraTarget it writes, and how, " &
                   "would be a guess about behaviour rather than about a name."),
    floatSetting("rifleAimSpeedZ", "Rifle aim speed Z", 3.0, lo = 0.0, hi = 10.0,
                 step = 0.1, category = "Camera", implemented = false,
                 description = "Read only. Same LerpCameraPatch semantics gap " &
                   "as rifleCameraZOffset; the per-axis speed fields are not " &
                   "identifiable without the upstream source."),

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
var gNoDomain = false
  ## The runtime is mapped but `il2cpp_init` built no domain. Only reachable
  ## on the sim side with `selfTestRuntime` pointed at a real client DLL.
  ## Every by-name lookup is skipped while this is set -- see the comment
  ## where it is assigned for the measurement.

proc openRuntime(): bool =
  ## Breadcrumbed, and not decoratively. A run measured on 2026-08-25 died
  ## silently -- no crash dump, no client log directory, no further host line --
  ## immediately after the last `reportType` in `onWorldReady`, which makes the
  ## next statement (this proc) the last thing that ran. Nothing inside here is
  ## IL2CPP work; it is `GetModuleHandleW` plus 65 `GetProcAddress` calls into
  ## an already-loaded module. So the next crashing run has to say WHICH of the
  ## three sub-steps it reached, because "somewhere in openRuntime" is not an
  ## answer and one more guess costs another launch.
  if rtOpen:
    return true
  bc "R1 openRuntime: about to openIl2Cpp"
  info "FOV: opening GameAssembly.dll from the mod (step 1/3)"
  rt = openIl2Cpp()
  info "FOV: GameAssembly.dll bound, loaded=" & $rt.loaded &
       " (step 2/3)"
  if not rt.loaded:
    return false
  bc "R2 openIl2Cpp returned; about to missingEssential"
  let missing = rt.missingEssential()
  bc "R3 missingEssential returned"
  info "FOV: essential entry points checked, " & $missing.len &
       " missing (step 3/3)"
  if missing.len > 0:
    warn "the IL2CPP runtime is missing " & $missing.len &
         " essential entry points; the fast path stays off"
    return false
  rtOpen = true
  result = true


# ---------------------------------------------------------------------------
# The world, asked of the HOST rather than of the type system
# ---------------------------------------------------------------------------
#
# `whenReady("EFT.GameWorld")` was A CHECK THAT CANNOT FAIL (CLAUDE.md 9b).
# It tests whether the TYPE RESOLVES, not whether a world exists, and
# `EFT.GameWorld` is an ordinary type in `Assembly-CSharp.dll` -- so it goes
# true the instant the IL2CPP runtime is up, MEASURED at ~1.4s, at the
# character screen, with no raid anywhere. The line it produced,
# "FOV: the game world is up", was false every single time it printed.
# morebots and sain were both disabled for exactly this shape of check.
#
# There is no by-name replacement, and none is invented:
# `EFT.GameWorld::get_Instance` DOES NOT EXIST on this build (measured: 409
# members, zero matches for "instance"). The only honest source is the host's
# own cache, populated by its `RegisterPlayer` detour and published as two
# exports -- the same route `mods/sain` uses.
{.emit: """
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <windows.h>

/* Calling a raw address needs C: nimony refuses `cast[proc(...)](pointer)`
 * outright. The int32 form is a REAL int32 thunk rather than the low half of
 * a pointer return -- an int32 return leaves the upper 32 bits of RAX
 * undefined, so a pointer-shaped read of it is a plausible non-zero answer
 * for a function that returned 0, which is a check that cannot fail. */
static void*   fov_gw_p_v  (void* f) { return ((void*  (*)(void))f)(); }
static int32_t fov_gw_i32_v(void* f) { return ((int32_t(*)(void))f)(); }
static void*   fov_ptr_add (void* p, int64_t d) { return (void*)((char*)p + d); }

/* THE WHOLE OF THIS FILE'S MEMORY SAFETY. Same bodies as `aowl_is_readable`
 * and `aowl_read_ptr` in abi/aowlspt_shim.h, restated locally because that
 * header is not in this mod's translation unit and pulling a shared ABI
 * header in would drop every build cache (CLAUDE.md 3) for three functions.
 * Kept byte-for-byte equivalent on purpose; if the shim's version is ever
 * tightened, tighten this one too. */
static int32_t fov_is_readable(void* p, int32_t size) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || size <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                         PAGE_EXECUTE_WRITECOPY))) return 0;
    {   /* the whole range has to lie inside this ONE committed region */
        uintptr_t start = (uintptr_t)mbi.BaseAddress;
        uintptr_t end   = start + (uintptr_t)mbi.RegionSize;
        uintptr_t need  = (uintptr_t)p + (uintptr_t)size;
        if (need < (uintptr_t)p) return 0;   /* overflow */
        return need <= end ? 1 : 0;
    }
}

/* Never called without `fov_is_readable` having said yes first -- see
 * `guardedField`, which is the only caller. */
static void* fov_read_ptr(void* p, int32_t off) {
    void* v = 0;
    if (!p) return 0;
    memcpy(&v, (const char*)p + off, sizeof(void*));
    return v;
}

static uint8_t fov_byte_at(void* p, uint64_t i) {
    return ((const uint8_t*)p)[i];
}

/* Crash-proof breadcrumbs. See `bc` in the nimony below for why the host log
 * could not be used. fopen/fputs/fflush/fclose per call: once fclose returns
 * the bytes belong to the file rather than to this process, so they outlive
 * an access violation. The file is truncated once, on the first call of a
 * run, so it is always exactly one run -- the same contract the host log
 * has. */
static int32_t fov_bc_n = 0;
static char fov_bc_path[1024] = {0};

/* THE ABSOLUTE PATH, resolved once and reportable.
 *
 * The first version passed the bare relative name to fopen, which resolved
 * against the process CWD. MEASURED: the file landed in D:\Aowlspt, one
 * directory ABOVE where this mod said to look, and the coordinator spent a
 * minute concluding "no crumbs were written" -- the exact wrong answer a
 * debugging aid must never give. So the path is resolved to an absolute one
 * up front and `fov_bc_where` hands it back, so the mod can PRINT where its
 * own crumbs go instead of asserting it. */
static const char* fov_bc_where(void) {
    if (!fov_bc_path[0]) {
        DWORD n = GetFullPathNameA("aowlspt-fov-breadcrumb.log",
                                   (DWORD)sizeof(fov_bc_path),
                                   fov_bc_path, NULL);
        if (n == 0 || n >= sizeof(fov_bc_path)) {
            /* Could not resolve it -- say so rather than invent a path. */
            strcpy(fov_bc_path, "(GetFullPathName failed)");
        }
    }
    return fov_bc_path;
}

static void fov_bc(const char* tag) {
    FILE* f = fopen(fov_bc_where(), fov_bc_n == 0 ? "w" : "a");
    if (!f) return;
    fov_bc_n++;
    /* No "
" escape anywhere in this emit block: nimony re-escapes the
     * string on its way into the generated C and a backslash-n does not
     * survive the trip. fputc(10) is the newline. */
    fprintf(f, "%04d ", (int)fov_bc_n);
    fputs(tag ? tag : "(null)", f);
    fputc(10, f);
    fflush(f);
    fclose(f);
}
static int32_t fov_bc_count(void) { return fov_bc_n; }

/* nimony has no `$cstring`, so the path comes back a character at a time
 * rather than as a pointer nimony would have to own. */
static int32_t fov_bc_where_len(void) { return (int32_t)strlen(fov_bc_where()); }
static int32_t fov_bc_where_at(int32_t i) {
    const char* p = fov_bc_where();
    int32_t n = (int32_t)strlen(p);
    return (i >= 0 && i < n) ? (int32_t)(unsigned char)p[i] : 0;
}
""".}

proc fovBcC(tag: cstring) {.importc: "fov_bc", nodecl.}
proc fovBcCount(): int32 {.importc: "fov_bc_count", nodecl.}
proc fovBcWhereLen(): int32 {.importc: "fov_bc_where_len", nodecl.}
proc fovBcWhereAt(i: int32): int32 {.importc: "fov_bc_where_at", nodecl.}

proc bcWhere(): string =
  ## The ABSOLUTE path the crumbs are actually going to. Printed rather than
  ## claimed -- see the C comment on `fov_bc_where` for the run that made
  ## that distinction expensive. Copied a character at a time because nimony
  ## has no `$cstring`; capped, like every other loop in this file.
  result = ""
  let n = fovBcWhereLen()
  if n <= 0 or n > 1024'i32:
    return "(unknown)"
  var i = 0'i32
  while i < n:
    result.add char(fovBcWhereAt(i))
    i = i + 1'i32

var gBcOn = true

proc bc(tag: string) =
  ## A CRASH-PROOF breadcrumb. Not a log line.
  ##
  ## WHY THIS IS NOT `info`. Twice now the host log's tail has been MISSING
  ## the lines immediately before death: the 2026-08-26 8.375s run showed no
  ## `reportType` output between "the game world is up" and "step 1/3", and
  ## the 9.703s run showed no "verifyHooks is off" line between the last
  ## summary line and the end of the file, although both are unconditional
  ## `info` calls sitting exactly there in the source. Whatever the cause,
  ## the consequence is the same and it is severe: THE LAST LOGGED LINE IS
  ## NOT THE LAST STATEMENT EXECUTED, so localising a crash by reading the
  ## log tail is off by an unknown number of statements. Six source-reasoning
  ## attempts have already been lost on this bug; spending another cycle on a
  ## breadcrumb that can evaporate would be a seventh.
  ##
  ## `fov_bc` does fopen("a") / fputs / fflush / fclose per call. Once
  ## `fclose` returns, the bytes are in the OS page cache and belong to the
  ## FILE, not to this process -- so they survive an access violation, which
  ## is exactly the failure mode being chased. It is slow (a syscall per
  ## breadcrumb) and that is affordable because it is capped and fires only
  ## on the arming path and the first driver tick, never per frame.
  if not gBcOn:
    return
  if fovBcCount() > 400'i32:
    # Capped iteration. A breadcrumb that fires forever is a per-frame file
    # open, which is its own outage.
    gBcOn = false
    return
  var t = tag
  fovBcC(toCString(t))

proc fovGwPV(f: Il2CppPtr): Il2CppPtr {.importc: "fov_gw_p_v", nodecl.}
proc fovGwI32V(f: Il2CppPtr): int32 {.importc: "fov_gw_i32_v", nodecl.}
proc fovPtrAdd(p: Il2CppPtr; d: int64): Il2CppPtr {.
  importc: "fov_ptr_add", nodecl.}

# `fov_is_readable` is a VirtualQuery: MEM_COMMIT, not PAGE_NOACCESS, not a
# guard page, and the WHOLE range inside one region. `fov_read_ptr`
# dereferences only after that check has passed -- see `guardedField`.
proc fovByteAt(p: Il2CppPtr; i: uint64): uint8 {.
  importc: "fov_byte_at", nodecl.}
proc fovReadPtrAt(p: Il2CppPtr; off: int32): Il2CppPtr {.
  importc: "fov_read_ptr", nodecl.}
proc fovIsReadable(p: Il2CppPtr; size: int32): int32 {.
  importc: "fov_is_readable", nodecl.}

proc fovReadable(p: Il2CppPtr; size: int): bool =
  result = p != nil and fovIsReadable(p, int32(size)) != 0'i32

proc fovGetModuleHandleA(name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetModuleHandleA", sideEffect.}
proc fovGetProcAddress(m: Il2CppPtr; name: cstring): Il2CppPtr {.
  stdcall, dynlib: "kernel32", importc: "GetProcAddress", sideEffect.}

var gGwFn: Il2CppPtr = cast[Il2CppPtr](0)
var gGwArmedFn: Il2CppPtr = cast[Il2CppPtr](0)
var gGwTried = false

proc gwResolve() =
  if gGwTried:
    return
  gGwTried = true
  var hostDll = "aowlspt-host-il2cpp.dll"
  let h = fovGetModuleHandleA(toCString(hostDll))
  if h == nil:
    return
  var n1 = "aowl_host_gameworld"
  var n2 = "aowl_host_gameworld_armed"
  gGwFn = fovGetProcAddress(h, toCString(n1))
  gGwArmedFn = fovGetProcAddress(h, toCString(n2))

proc gwState(): int =
  ## 0 no host export -- host too old, or this is not the client
  ## 1 export present but NO detour armed -- INCONCLUSIVE, not "no raid"
  ## 2 armed, cache empty -- genuinely not in a raid
  ## 3 world live
  ##
  ## Three-way on purpose (CLAUDE.md 9b): "I could not look" is not "no
  ## world". The armed flag is read through a REAL int32 thunk rather than
  ## the low half of a pointer return, because an int32 return leaves the
  ## upper 32 bits of RAX undefined and a pointer-shaped read of it would be
  ## a plausible non-zero answer for a function that returned 0.
  gwResolve()
  if gGwFn == nil:
    return 0
  if gGwArmedFn != nil and fovGwI32V(gGwArmedFn) == 0'i32:
    return 1
  if fovGwPV(gGwFn) == nil:
    return 2
  result = 3

proc gwStateText(): string =
  case gwState()
  of 0: "no host export aowl_host_gameworld -- this host predates it, or " &
        "this mod is not running in the client. INCONCLUSIVE."
  of 1: "the host exports the world but NO detour is armed to populate it " &
        "(host flag debugEsp or botDiag). INCONCLUSIVE -- not 'no raid'."
  of 2: "armed; no GameWorld cached, which is exactly what a menu looks like"
  else: "GameWorld LIVE, borrowed from the host's RegisterPlayer cache"

proc gwWorld(): Il2CppPtr =
  ## The live world object, or nil. Never a type handle.
  result = cast[Il2CppPtr](0)
  if gwState() == 3:
    result = fovGwPV(gGwFn)

# ---------------------------------------------------------------------------
# Static RVAs, byte-verified. The ONLY way this mod reaches a named method.
# ---------------------------------------------------------------------------
#
# WHY EVERY BY-NAME LOOKUP IS GONE FROM THE CLIENT PATH.
#
# MEASURED. `il2cpp_class_from_name` and `il2cpp_class_get_method_from_name`
# hand back NON-NIL garbage on this build.
#
# THE MECHANISM, corrected 2026-08-26 by an offline disassembly (see
# docs/IL2CPP_EXPORTS.md on feat-il2cpp-export-map). The earlier wording here
# -- "returns a pointer into unmapped memory", fact #35 -- described the
# symptom and got the cause wrong, and a wrong cause encoded in a refusal
# string is a confidently wrong diagnostic. What is actually true: this is
# STOCK IL2CPP with a TOKEN-GATED export ABI. 38 of the 241 exports take an
# extra trailing 32-byte token argument that nothing in this repo passes, and
# when the token does not match they return a UNIFORM RANDOM NON-ZERO uint64
# drawn from a per-thread MT19937-64.
#
# That is why `if cls == nil` is a check that CANNOT FAIL: the failure value
# is deliberately never zero. The call "succeeds", and the process dies at
# the first dereference of a random 64-bit number.
#
# It does not change the design one bit -- a direct call at a static RVA
# bypasses the export ABI entirely and needs no token -- but it does change
# what we are entitled to say, so the strings say the true thing now.
#
# `fast.nim`'s `findClass` walks every loaded image calling
# `il2cpp_class_from_name`; `bindMethod` hands the result to `findMethod`,
# which DEREFERENCES it. So `if cls == nil` is a check that CANNOT FAIL, the
# resolution reads as a success, and the process dies at the first read
# through the handle -- instantly, silently, with a client log byte-identical
# to a healthy run.
#
# MEASURED in THIS client, 2026-08-26: staging fov.dll killed it at 8.375s,
# the last host line being `essential entry points checked, 0 missing
# (step 3/3)`. The next statement executed was `bindFovStatics`, whose first
# act was `bindMethod(rt, "EFT.GameWorld", "get_Instance", 0)`. Removing ONLY
# fov.dll, every other mod unchanged, gave a healthy client (alive, `Unity
# thread live` at 14.1s, run length 1:14 and climbing). That is a clean
# isolation.
#
# What survives, and why:
#   * `openIl2Cpp` / `missingEssential` -- GetModuleHandleW plus
#     GetProcAddress. No IL2CPP call at all. (The dead run reached the end of
#     these, which is how we know.)
#   * `bindOnObject` -- resolves against `il2cpp_object_get_class` of a LIVE
#     receiver. The class comes out of a real object header, not out of a name.
#   * a raw field read at a metadata-derived offset, behind VirtualQuery.
#   * a direct call at a static RVA whose 16 prologue bytes match.
# Everything else refuses, loudly, and says which of these it wanted.
#
# The RVAs and prologue bytes below were produced offline by
# `tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll
# .cache/global-metadata.dec.dat type 13527` and `... bytes <RVA> 16`; the
# field offsets by `tools/fldoff.py fields EFT.CameraControl.*`, which
# self-checks `System.String._stringLength@0x10` before printing anything.
# Nothing here is remembered, and nothing is guessed.

const
  RvaCamInstance = 0x1263bd0
    ## EFT.CameraControl.CameraManager::get_Instance() -> CameraManager.
    ## rid=81680, arity 0, STATIC, section `il2cpp`, a real body (no thunk
    ## shape matched, and the bytes below are a stack frame, not a jump).
  ProCamInstance = "48 83 EC 28 80 3D E6 8B E5 05 00 75 18 48 8D 0D"

  RvaSetFov3 = 0x1268d20
    ## EFT.CameraControl.CameraManager::SetFov(float x, float time,
    ## bool applyFovOnCamera). rid=81746, arity 3, INSTANCE, real body.
    ##
    ## The arity is settled HERE, from offline metadata, rather than by
    ## asking the live runtime -- `signatureOf` was the by-name call that
    ## killed the client. The one-argument overload `SetFov(float targetFov)`
    ## exists too, at 0x1268F90, and is deliberately NOT used: the
    ## three-argument form is the one upstream calls and the one whose
    ## `applyFovOnCamera` flag makes the write reach the camera.
  ProSetFov3 = "48 89 5C 24 10 56 48 83 EC 40 80 3D AD 3A E5 05"

  RvaGetKey = 0x531eae0
    ## UnityEngine.Input::GetKey(KeyCode) -> bool. rid=41, arity 1, STATIC,
    ## from `il2cpp_resolve.py type 30607 --shared`. It shares its RVA with
    ## `GetKeyInt(KeyCode)` -- the same body under its internal name. A
    ## shared RVA is a hazard for a DETOUR, which has unbounded blast
    ## radius; this CALLS it, with the argument it is correct for, so
    ## sharedness is not a risk here.
  ProGetKey = "40 53 48 83 EC 20 48 8B 05 2B 72 DB 01 8B D9 48"

  RvaGetKeyDown = 0x531eb80
    ## UnityEngine.Input::GetKeyDown(KeyCode) -> bool. rid=45, arity 1,
    ## STATIC, same source, same alias pair (`GetKeyDownInt`). Both bodies
    ## sit in the `il2cpp` section and neither is the universal empty-body
    ## stub at 0x628110 -- checked with `bytes`, which printed a real stack
    ## frame, not `C2 00 00`.
  ProGetKeyDown = "40 53 48 83 EC 20 48 8B 05 9B 71 DB 01 8B D9 48"

  KeyIntervalNs = 2_000_000'i64
    ## The key poll runs BEFORE the FOV rate gate, because `GetKeyDown` is
    ## true for exactly one frame and a gate that skips that frame eats the
    ## press. It therefore needs a gate of its own: the hook this rides on
    ## fires once per PLAYER per frame (every bot included), so an ungated
    ## poll would be forty calls a frame rather than one.
    ##
    ## 500 Hz, stated as a falsifiable limit rather than as a safe number:
    ## up to 500 fps this is at most one poll per frame and misses no edge;
    ## above 500 fps a toggle press can be missed. `holdToZoom` (the
    ## default) reads a level, not an edge, and is unaffected either way.

  # Field offsets. These replace three by-name property getters outright:
  # `get_Camera` on BOTH managers resolves to 0x65ED10, whose bytes are
  # `48 8B 41 70 C3` -- `mov rax,[rcx+0x70]; ret`. The getter IS the field
  # read, and that RVA is a FOLDED body shared with every other `+0x70`
  # reference getter in the build. Reading the field gives the identical
  # answer with no shared-RVA exposure and no call at all.
  OffCamManagerCamera = 0x70   ## CameraManager.<Camera>k__BackingField
  OffCamManagerOptic  = 0x10   ## CameraManager.<OpticCameraManager>k__BackingField
  OffOpticCamera      = 0x70   ## OpticCameraManager.<Camera>k__BackingField

var gRvaVerified = 0
var gRvaRejected = 0
var gByNameRefusals = 0

proc hexDigit(v: int): char =
  const D = "0123456789ABCDEF"
  result = D[v and 15]

proc hex2(v: int): string =
  result = ""
  result.add hexDigit(v shr 4)
  result.add hexDigit(v)

proc hexs(v: int): string =
  ## Lowercase, no padding -- the way an RVA is written everywhere else here.
  const D = "0123456789abcdef"
  if v == 0:
    return "0"
  var n = v
  var buf = ""
  while n > 0:
    buf.add D[n and 15]
    n = n shr 4
  result = ""
  var i = buf.len - 1
  while i >= 0:
    result.add buf[i]
    dec i

proc prologueMatches(p: Il2CppPtr; expect: string; got: var string): bool =
  ## An exact 16-byte compare against the bytes `il2cpp_resolve.py` read out
  ## of `GameAssembly.dll` on disk, with the LIVE bytes printed on a mismatch
  ## so the refusal carries its own evidence.
  ##
  ## Compared against live memory ON PURPOSE, and that is a considered choice
  ## rather than the trap CLAUDE.md warns about. The startup-snapshot rule
  ## exists for DETOUR targets, where an earlier feature's trampoline makes a
  ## perfectly correct RVA self-reject. Nothing in this mod detours either of
  ## these two functions -- they are only ever CALLED -- and the snapshot
  ## table in `abi/aowlspt_prologue.h` is `static`, i.e. host-internal, so a
  ## mod that included it would get its own empty table and lazily capture
  ## whatever is there NOW, which is strictly worse than reading the bytes
  ## directly. A mismatch here therefore means either a stale RVA or somebody
  ## else's hook, and in both of those cases declining to call is correct.
  ## The failure mode is a loud refusal, never a crash.
  got = ""
  result = false
  if p == nil:
    got = "(null)"
    return
  if not fovReadable(p, 16):
    got = "(not readable -- VirtualQuery says this is not committed memory)"
    return
  var i = 0
  var ok = true
  while i < 16:
    let b = int(fovByteAt(p, uint64(i)))
    var hi = 0
    var lo = 0
    let ch = expect[i * 3]
    let cl = expect[i * 3 + 1]
    if ch >= '0' and ch <= '9': hi = int(ch) - int('0')
    else: hi = 10 + int(ch) - int('A')
    if cl >= '0' and cl <= '9': lo = int(cl) - int('0')
    else: lo = 10 + int(cl) - int('A')
    if b != hi * 16 + lo:
      ok = false
    if i > 0:
      got.add ' '
    got = got & hex2(b)
    inc i
  result = ok

proc bindAtRva(label: string; rva: int; expect: string;
               argKinds: openArray[FastKind]; ret: FastKind;
               isStatic: bool): Binding =
  ## A `Binding` built from a static RVA instead of from a name.
  ##
  ## `info` -- the hidden trailing `const MethodInfo*` -- is left NULL. That
  ## is legal for everything except a shared generic, and neither of these is
  ## generic: `il2cpp_resolve.py type 13527` prints both signatures in full
  ## with no type parameters and no generic container.
  result = Binding(ok: false, why: "", target: label,
                   fn: cast[Il2CppPtr](0), info: cast[Il2CppPtr](0),
                   argc: 0'i32, slots: 0'i32, mask: 0'u32, ret: ret,
                   isStatic: isStatic, bindNs: 0'i64)
  if not rtOpen or rt.handle == nil:
    result.why = label & ": GameAssembly.dll is not bound, so there is no " &
                 "imagebase to add an RVA to"
    gRvaRejected = gRvaRejected + 1
    return
  if argKinds.len > MaxArgs:
    result.why = label & ": " & $argKinds.len & " arguments; the fast path " &
                 "passes at most " & $MaxArgs
    gRvaRejected = gRvaRejected + 1
    return
  if ret == fkNone:
    result.why = label & ": the return shape was not stated"
    gRvaRejected = gRvaRejected + 1
    return
  # Runtime address = module base + (VA - 0x180000000), and the RVAs above
  # are already VA-minus-imagebase.
  let fn = fovPtrAdd(rt.handle, int64(rva))
  var got = ""
  if not prologueMatches(fn, expect, got):
    result.why = label & " @0x" & hexs(rva) & ": PROLOGUE MISMATCH -- " &
                 "expected " & expect & ", found " & got & ". REFUSED; " &
                 "nothing was called and nothing was written. Either this " &
                 "RVA is stale for the installed GameAssembly.dll (a Tarkov " &
                 "update), or another feature has already detoured it."
    gRvaRejected = gRvaRejected + 1
    return
  let base = (if isStatic: 0'i32 else: 1'i32)
  var mask = 0'u32
  var i = 0
  while i < argKinds.len:
    let k = argKinds[i]
    if k == fkNone or k == fkVoid or k == fkF64:
      result.why = label & ": argument " & $i & " is " & describe(k) &
                   ", which the fast path does not pass"
      gRvaRejected = gRvaRejected + 1
      return
    if k == fkF32:
      mask = mask or (1'u32 shl uint32(int32(i) + base))
    inc i
  result.fn = fn
  result.argc = int32(argKinds.len)
  result.slots = int32(argKinds.len) + base
  result.mask = mask
  result.ok = true
  gRvaVerified = gRvaVerified + 1
  result.why = label & " @0x" & hexs(rva) &
               ": prologue verified 16/16, " &
               (if isStatic: "static" else: "instance") & ", " &
               $argKinds.len & " arg(s)"

proc guardedField(obj: Il2CppPtr; off: int; what: string): Il2CppPtr =
  ## One hop along a reference-field chain, with the hop validated.
  ##
  ## Every hop is checked, not just the first: `a->b->c` is three checks. The
  ## object must be readable for `off+8` bytes before the load, and the
  ## result must itself be readable before anyone treats it as an object.
  result = cast[Il2CppPtr](0)
  if obj == nil:
    return
  if not fovReadable(obj, off + 8):
    return
  let p = fovReadPtrAt(obj, int32(off))
  if p == nil:
    return
  if not fovReadable(p, 16):
    return
  result = p

# ---------------------------------------------------------------------------
# UnityEngine.KeyCode: name -> ordinal
# ---------------------------------------------------------------------------
#
# GENERATED, not remembered. The table below is the verbatim output of
#
#     python tools/fldoff.py enum UnityEngine.KeyCode
#
# against the installed GameAssembly.dll -- all 328 members, in metadata
# order. Nothing here was typed from memory, which is the entire reason these
# two settings were inert until now.
#
# The history matters, because the old refusal was honest and the correction
# is what changed. KeyCode's constants are LITERAL (attrs 0x8056) and live in
# metadata property 8, `fieldAndParameterDefaultValueData`. That blob is NOT
# encrypted -- it stores I4/U4 as ECMA-335 compressed integers, BIG-ENDIAN and
# zigzagged, not as raw int32. Reading four raw bytes at `KeyCode.None` (a
# single 0x00 byte) swallowed the next three constants and produced
# -25161728, which is exactly the number this file used to quote as proof the
# blob "does not decode". It decodes; the READER was wrong.
# `il2cpp_resolve.py verify-consts` now checks the decoder against 19
# independently-known values (KeyCode None/Space/A/Alpha0 plus one per
# primitive width) and prints CONSTANT DECODER SELF-CHECK PASSED.

const
  KeyCodeTable =
    "None=0,Backspace=8,Delete=127,Tab=9,Clear=12,Return=13,Pause=19,Es" &
    "cape=27,Space=32,Keypad0=256,Keypad1=257,Keypad2=258,Keypad3=259,K" &
    "eypad4=260,Keypad5=261,Keypad6=262,Keypad7=263,Keypad8=264,Keypad9" &
    "=265,KeypadPeriod=266,KeypadDivide=267,KeypadMultiply=268,KeypadMi" &
    "nus=269,KeypadPlus=270,KeypadEnter=271,KeypadEquals=272,UpArrow=27" &
    "3,DownArrow=274,RightArrow=275,LeftArrow=276,Insert=277,Home=278,E" &
    "nd=279,PageUp=280,PageDown=281,F1=282,F2=283,F3=284,F4=285,F5=286," &
    "F6=287,F7=288,F8=289,F9=290,F10=291,F11=292,F12=293,F13=294,F14=29" &
    "5,F15=296,Alpha0=48,Alpha1=49,Alpha2=50,Alpha3=51,Alpha4=52,Alpha5" &
    "=53,Alpha6=54,Alpha7=55,Alpha8=56,Alpha9=57,Exclaim=33,DoubleQuote" &
    "=34,Hash=35,Dollar=36,Percent=37,Ampersand=38,Quote=39,LeftParen=4" &
    "0,RightParen=41,Asterisk=42,Plus=43,Comma=44,Minus=45,Period=46,Sl" &
    "ash=47,Colon=58,Semicolon=59,Less=60,Equals=61,Greater=62,Question" &
    "=63,At=64,LeftBracket=91,Backslash=92,RightBracket=93,Caret=94,Und" &
    "erscore=95,BackQuote=96,A=97,B=98,C=99,D=100,E=101,F=102,G=103,H=1" &
    "04,I=105,J=106,K=107,L=108,M=109,N=110,O=111,P=112,Q=113,R=114,S=1" &
    "15,T=116,U=117,V=118,W=119,X=120,Y=121,Z=122,LeftCurlyBracket=123," &
    "Pipe=124,RightCurlyBracket=125,Tilde=126,Numlock=300,CapsLock=301," &
    "ScrollLock=302,RightShift=303,LeftShift=304,RightControl=305,LeftC" &
    "ontrol=306,RightAlt=307,LeftAlt=308,LeftMeta=310,LeftCommand=310,L" &
    "eftApple=310,LeftWindows=311,RightMeta=309,RightCommand=309,RightA" &
    "pple=309,RightWindows=312,AltGr=313,Help=315,Print=316,SysReq=317," &
    "Break=318,Menu=319,Mouse0=323,Mouse1=324,Mouse2=325,Mouse3=326,Mou" &
    "se4=327,Mouse5=328,Mouse6=329,JoystickButton0=330,JoystickButton1=" &
    "331,JoystickButton2=332,JoystickButton3=333,JoystickButton4=334,Jo" &
    "ystickButton5=335,JoystickButton6=336,JoystickButton7=337,Joystick" &
    "Button8=338,JoystickButton9=339,JoystickButton10=340,JoystickButto" &
    "n11=341,JoystickButton12=342,JoystickButton13=343,JoystickButton14" &
    "=344,JoystickButton15=345,JoystickButton16=346,JoystickButton17=34" &
    "7,JoystickButton18=348,JoystickButton19=349,Joystick1Button0=350,J" &
    "oystick1Button1=351,Joystick1Button2=352,Joystick1Button3=353,Joys" &
    "tick1Button4=354,Joystick1Button5=355,Joystick1Button6=356,Joystic" &
    "k1Button7=357,Joystick1Button8=358,Joystick1Button9=359,Joystick1B" &
    "utton10=360,Joystick1Button11=361,Joystick1Button12=362,Joystick1B" &
    "utton13=363,Joystick1Button14=364,Joystick1Button15=365,Joystick1B" &
    "utton16=366,Joystick1Button17=367,Joystick1Button18=368,Joystick1B" &
    "utton19=369,Joystick2Button0=370,Joystick2Button1=371,Joystick2But" &
    "ton2=372,Joystick2Button3=373,Joystick2Button4=374,Joystick2Button" &
    "5=375,Joystick2Button6=376,Joystick2Button7=377,Joystick2Button8=3" &
    "78,Joystick2Button9=379,Joystick2Button10=380,Joystick2Button11=38" &
    "1,Joystick2Button12=382,Joystick2Button13=383,Joystick2Button14=38" &
    "4,Joystick2Button15=385,Joystick2Button16=386,Joystick2Button17=38" &
    "7,Joystick2Button18=388,Joystick2Button19=389,Joystick3Button0=390" &
    ",Joystick3Button1=391,Joystick3Button2=392,Joystick3Button3=393,Jo" &
    "ystick3Button4=394,Joystick3Button5=395,Joystick3Button6=396,Joyst" &
    "ick3Button7=397,Joystick3Button8=398,Joystick3Button9=399,Joystick" &
    "3Button10=400,Joystick3Button11=401,Joystick3Button12=402,Joystick" &
    "3Button13=403,Joystick3Button14=404,Joystick3Button15=405,Joystick" &
    "3Button16=406,Joystick3Button17=407,Joystick3Button18=408,Joystick" &
    "3Button19=409,Joystick4Button0=410,Joystick4Button1=411,Joystick4B" &
    "utton2=412,Joystick4Button3=413,Joystick4Button4=414,Joystick4Butt" &
    "on5=415,Joystick4Button6=416,Joystick4Button7=417,Joystick4Button8" &
    "=418,Joystick4Button9=419,Joystick4Button10=420,Joystick4Button11=" &
    "421,Joystick4Button12=422,Joystick4Button13=423,Joystick4Button14=" &
    "424,Joystick4Button15=425,Joystick4Button16=426,Joystick4Button17=" &
    "427,Joystick4Button18=428,Joystick4Button19=429,Joystick5Button0=4" &
    "30,Joystick5Button1=431,Joystick5Button2=432,Joystick5Button3=433," &
    "Joystick5Button4=434,Joystick5Button5=435,Joystick5Button6=436,Joy" &
    "stick5Button7=437,Joystick5Button8=438,Joystick5Button9=439,Joysti" &
    "ck5Button10=440,Joystick5Button11=441,Joystick5Button12=442,Joysti" &
    "ck5Button13=443,Joystick5Button14=444,Joystick5Button15=445,Joysti" &
    "ck5Button16=446,Joystick5Button17=447,Joystick5Button18=448,Joysti" &
    "ck5Button19=449,Joystick6Button0=450,Joystick6Button1=451,Joystick" &
    "6Button2=452,Joystick6Button3=453,Joystick6Button4=454,Joystick6Bu" &
    "tton5=455,Joystick6Button6=456,Joystick6Button7=457,Joystick6Butto" &
    "n8=458,Joystick6Button9=459,Joystick6Button10=460,Joystick6Button1" &
    "1=461,Joystick6Button12=462,Joystick6Button13=463,Joystick6Button1" &
    "4=464,Joystick6Button15=465,Joystick6Button16=466,Joystick6Button1" &
    "7=467,Joystick6Button18=468,Joystick6Button19=469,Joystick7Button0" &
    "=470,Joystick7Button1=471,Joystick7Button2=472,Joystick7Button3=47" &
    "3,Joystick7Button4=474,Joystick7Button5=475,Joystick7Button6=476,J" &
    "oystick7Button7=477,Joystick7Button8=478,Joystick7Button9=479,Joys" &
    "tick7Button10=480,Joystick7Button11=481,Joystick7Button12=482,Joys" &
    "tick7Button13=483,Joystick7Button14=484,Joystick7Button15=485,Joys" &
    "tick7Button16=486,Joystick7Button17=487,Joystick7Button18=488,Joys" &
    "tick7Button19=489,Joystick8Button0=490,Joystick8Button1=491,Joysti" &
    "ck8Button2=492,Joystick8Button3=493,Joystick8Button4=494,Joystick8" &
    "Button5=495,Joystick8Button6=496,Joystick8Button7=497,Joystick8But" &
    "ton8=498,Joystick8Button9=499,Joystick8Button10=500,Joystick8Butto" &
    "n11=501,Joystick8Button12=502,Joystick8Button13=503,Joystick8Butto" &
    "n14=504,Joystick8Button15=505,Joystick8Button16=506,Joystick8Butto" &
    "n17=507,Joystick8Button18=508,Joystick8Button19=509"

proc kcFold(x: char): int =
  ## ASCII lower-case, without `chr` and without a stdlib import.
  result = int(x)
  if result >= 65 and result <= 90:
    result = result + 32

proc kcEq(a, b: string): bool =
  if a.len != b.len:
    return false
  var i = 0
  while i < a.len:
    if kcFold(a[i]) != kcFold(b[i]):
      return false
    inc i
  result = true

proc keyCodeOrdinal(name: string): int =
  ## The `UnityEngine.KeyCode` ordinal for a configured key name, or -1.
  ##
  ## -1 is a REFUSAL, not a key: `KeyCode.None` is genuinely 0, so "unknown"
  ## and "None" must never collapse onto the same answer. Case-insensitive,
  ## because config.json is written by a human.
  result = -1
  if name.len == 0:
    return
  let t = KeyCodeTable
  var i = 0
  while i < t.len:
    var j = i
    while j < t.len and t[j] != '=':
      inc j
    if j >= t.len:
      return
    var k = j + 1
    while k < t.len and t[k] != ',':
      inc k
    var nm = ""
    var q = i
    while q < j:
      nm.add t[q]
      inc q
    if kcEq(nm, name):
      var v = 0
      var r = j + 1
      while r < k:
        v = v * 10 + (int(t[r]) - int('0'))
        inc r
      return v
    i = k + 1

proc signatureOf(owner, member: string; argc: int;
                 params: var seq[string]; ret: var string): bool =
  ## The declared parameter types and return type of a method, from the
  ## runtime's own metadata. `argc` of -1 matches any arity, exactly as the
  ## host's `patch` does.
  params = @[]
  ret = ""
  result = false
  if side() == sideClient:
    # REFUSED IN THE CLIENT, ALWAYS. This proc is `findClass` + `findMethod`
    # followed by a DEREFERENCE of the handle that comes back, and on this
    # build that is fatal -- see the RVA section above for the measurement.
    # It is left compiled rather than deleted because the sim side has no
    # IL2CPP runtime under it at all and the self-test wants the shape.
    #
    # Every caller of this treats `false` as "refuse the effect and say so",
    # which is why turning it off here disarms the three by-name effects
    # (`CalculateScaleValueByFov`, `get_GetCurrentSensitivity`,
    # `get_AimingSensitivity`) at their first line, with their own reasons.
    gByNameRefusals = gByNameRefusals + 1
    # Suspect (b) on the coordinator's list, answered as EVIDENCE rather than
    # as a counter. This crumb is written BEFORE the return, so its presence
    # proves the client path reached the guard and turned back. The summary
    # counter it replaces only ever proved that a number had been
    # incremented somewhere, which is not the same claim.
    bc("N* signatureOf DECLINED (nothing looked up): " & owner & "::" & member)
    return false
  if not rtOpen:
    return false
  # A check that CAN fail, and does. MEASURED offline 2026-08-26: pointing
  # `selfTestRuntime` at the real `D:\Games\Tarkov\GameAssembly.dll` and
  # running `aowl run mods/fov` gets past both verified RVAs and then dies at
  # 0xC0000005 in the first by-name probe -- because `il2cpp_init` out of
  # process returns no domain (the metadata is decrypted during the game's
  # own startup), and the by-name path walks structures that were never
  # built. That is the same failure reproduced in a throwaway process, and
  # the reason the sim self-test could not be run against a real runtime
  # without taking the sim down.
  if gNoDomain:
    gByNameRefusals = gByNameRefusals + 1
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
  if side() == sideClient:
    # Belt and braces. Unreachable in the client today -- every caller is
    # behind a `signatureOf` that already refused -- but this proc contains a
    # `findClass`, and "unreachable" is a property of today's call graph
    # rather than of this proc. Refusing here means no future edit can
    # reintroduce the fatal route by accident.
    why = "REFUSED in the client: classifying a parameter needs findClass, " &
          "which on this build returns a non-nil pointer into unmapped " &
          "memory: the export ABI is token-gated and returns random " &
          "non-zero garbage when the token is absent"
    gByNameRefusals = gByNameRefusals + 1
    return false
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
var bCamInstance: Binding      ## CameraManager::get_Instance, static RVA
var bSetFov: Binding           ## CameraManager::SetFov(f,f,b), static RVA
var bGetKey: Binding           ## Input::GetKey(KeyCode), static RVA
var bGetKeyDown: Binding       ## Input::GetKeyDown(KeyCode), static RVA
  ## `bWorld` is GONE. There is no `EFT.GameWorld::get_Instance` on this
  ## build (409 members, zero matches), the by-name attempt to find one was
  ## the statement that killed the client, and the world now arrives from
  ## the host export `aowl_host_gameworld` as an already-live object.

var obMainPlayer: ObjBind      ## on the world object
var obPwa: ObjBind             ## on the player object
var obIsAiming: ObjBind        ## on the weapon animation object
var obScope: ObjBind           ## on the weapon animation object
var obIsOptic: ObjBind         ## on the scope object, whose class is not CurrentScope's declared type
var obCamFov: ObjBind          ## on the UnityEngine.Camera object

var gSetFovArgc = 0
var gOpticChainState = "not attempted"
var gBaseFov = 0.0
var gLastFovTicks = 0'i64
var gFovNs = 0'i64
var gFovSamples = 0
var gFovBoundSaid = false

var gZoomKeyCode = -1          ## resolved from cfgZoomToggleKey; -1 = refused
var gZoomKeyState = "not attempted"
var gZoomLatch = false         ## the toggle latch, when holdToZoom is off
var gZoomOn = false            ## what the last poll decided
var gZoomFrames = 0'i64        ## FOV writes taken with the zoom key asserted
var gLastAiming = false
var gLastKeyTicks = 0'i64

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

proc keyKinds(): seq[FastKind] =
  ## `bool GetKey(KeyCode key)`. A KeyCode is an enum over Int32, so its
  ## register class is `fkI32` -- one general-purpose register. Stated from
  ## the offline signature (`il2cpp_resolve.py type 30607`), not inferred by
  ## `classifyType`, which is the by-name route this file does not take.
  result = @[fkI32]

proc setFovKinds3(): seq[FastKind] =
  ## The register classes of `SetFov(float x, float time, bool
  ## applyFovOnCamera)`, in declaration order.
  ##
  ## Stated rather than inferred, because inferring means `classifyType`,
  ## which means `findClass`, which is the fatal by-name route. The types
  ## themselves are not remembered either -- they are the signature
  ## `il2cpp_resolve.py` printed for rid 81746, quoted in `RvaSetFov3`'s
  ## doc comment, and the prologue compare is what ties that signature to
  ## the DLL actually installed.
  result = @[]
  result.add fkF32
  result.add fkF32
  result.add fkBool

proc bindFovStatics(): bool =
  ## The two members that have no object to bind against yet. Everything else in
  ## the chain is bound on the first frame the object it lives on exists.
  obMainPlayer = noObjBind()
  obPwa = noObjBind()
  obIsAiming = noObjBind()
  obScope = noObjBind()
  obIsOptic = noObjBind()
  obCamFov = noObjBind()

  # Both are attempted before either is judged, so the report has a `why` for
  # each. An early return here left the second `Binding` zeroed, and a zeroed
  # one reports an empty reason -- which reads as "no reason given" rather than
  # "never asked".
  # THE LINE THAT KILLED THE CLIENT, and what replaced it.
  #
  # This used to be
  #     bWorld      = bindMethod(rt, TyGameWorld, "get_Instance", 0)
  #     bCamInstance = bindMethod(rt, TyCamera,   "get_Instance", 0)
  # and the first of those was the last statement the process ever executed
  # (measured 2026-08-26, death at 8.375s immediately after `step 3/3`).
  #
  # `EFT.GameWorld::get_Instance` does not exist at all -- 409 members, zero
  # matches -- so `bWorld` was never going to bind even on a build where
  # asking was survivable. It is GONE, not repaired: the world now comes from
  # the host export, as an object, and `bWorld` is retired.
  info "FOV: binding CameraManager::get_Instance at a verified static RVA " &
       "(no name is looked up, so the token-gated export ABI is not " &
       "involved at all)"
  # Given a reason BEFORE the early return below can strand it. A zeroed
  # `Binding` reports an empty `why`, which reads in a log as "no reason
  # given" rather than "never asked" -- the exact defect the comment above
  # this proc was written about, reintroduced by the rewrite and caught by
  # the sim self-test printing a bare "REFUSED ... -- ".
  bSetFov = Binding(ok: false,
                    why: "not attempted: CameraManager::get_Instance had to " &
                         "verify first, and did not",
                    target: "CameraManager::SetFov(float,float,bool)",
                    fn: cast[Il2CppPtr](0), info: cast[Il2CppPtr](0),
                    argc: 0'i32, slots: 0'i32, mask: 0'u32, ret: fkVoid,
                    isStatic: false, bindNs: 0'i64)
  bc "S1 about to prologue-verify get_Instance"
  bCamInstance = bindAtRva("CameraManager::get_Instance", RvaCamInstance,
                           ProCamInstance, noKinds(), fkPtr, true)
  if not bCamInstance.ok:
    gFovState = "refused: " & bCamInstance.why
    warn "FOV: " & gFovState
    return false
  info "FOV: " & bCamInstance.why

  # `SetFov` is the one place upstream's call shape has to be confirmed rather
  # than remembered. Two overloads are accepted, and only if the runtime says
  # the parameters are what this would pass; anything else is refused with the
  # signature printed, which is the line somebody needs in order to fix it.
  # The arity is settled here, by name; the *binding* is taken later against the
  # camera manager object, because a subclass may override it.
  # `SetFov`'s call shape, settled OFFLINE instead of by asking the runtime.
  #
  # This used to be three `signatureOf` calls, i.e. three more `findClass` +
  # `findMethod` pairs, i.e. three more chances to die. The answer they were
  # reaching for is a constant of the installed GameAssembly.dll and is now
  # read from it by `tools/il2cpp_resolve.py` at build time:
  #     void SetFov(float x, float time, bool applyFovOnCamera)  rid=81746
  # so the arity is 3 and the register shape is (f32, f32, bool). The
  # prologue compare below is what makes that a CHECK rather than a memory:
  # if the installed DLL is not the one those bytes came from, this refuses.
  bc "S2 get_Instance verified; about to prologue-verify SetFov"
  bSetFov = bindAtRva("CameraManager::SetFov(float,float,bool)", RvaSetFov3,
                      ProSetFov3, setFovKinds3(), fkVoid, false)
  if not bSetFov.ok:
    gFovState = "refused: " & bSetFov.why
    warn "FOV: " & gFovState
    return false
  gSetFovArgc = 3
  info "FOV: " & bSetFov.why

  # The toggle-zoom key. NON-FATAL by construction: a refusal here leaves
  # the FOV write exactly as it was and is reported on its own line,
  # because a missing key must not take down the effect that works.
  bc "S3a about to prologue-verify Input::GetKey / GetKeyDown"
  bGetKey = bindAtRva("Input::GetKey(KeyCode)", RvaGetKey, ProGetKey,
                      keyKinds(), fkBool, true)
  bGetKeyDown = bindAtRva("Input::GetKeyDown(KeyCode)", RvaGetKeyDown,
                          ProGetKeyDown, keyKinds(), fkBool, true)
  if bGetKey.ok and bGetKeyDown.ok:
    info "FOV: " & bGetKey.why
    info "FOV: " & bGetKeyDown.why
  else:
    warn "FOV: toggle zoom refused -- " &
         (if bGetKey.ok: bGetKeyDown.why else: bGetKey.why)
  gZoomKeyDirty = true

  bc "S3 both RVAs verified; bindFovStatics returning true"
  gFovState = "arming: SetFov verified at 0x" & hexs(RvaSetFov3) &
              " with 3 argument(s); waiting for a live CameraManager"
  result = true


proc bindOpticCamera(): bool =
  ## The optic camera, for the sensitivity table -- reached by WALKING, not
  ## by a name.
  ##
  ## This used to try two by-name spellings of a container's static
  ## `get_Instance`. Both were `bindMethod`, i.e. both were fatal, and both
  ## were also WRONG: `tools/il2cpp_resolve.py type 13529` lists every member
  ## of `EFT.CameraControl.OpticCameraManager` and there is no `Instance`
  ## among them, and `OpticCameraManagerContainer` is not a type on this build
  ## at all. So the old code could only ever have refused -- after possibly
  ## killing the process on the way.
  ##
  ## The real route is a field walk from a manager we already hold:
  ##   CameraManager.Instance
  ##     -> <OpticCameraManager>k__BackingField @0x10
  ##       -> <Camera>k__BackingField           @0x70
  ## both offsets from `tools/fldoff.py`. No name is resolved, every hop is
  ## VirtualQuery'd, and a nil at any hop means "no optic", which is exactly
  ## what the caller wants to hear.
  if bCamInstance.ok:
    gOpticChainState = "walking CameraManager.Instance -> OpticCameraManager" &
                       " @0x10 -> Camera @0x70 (field reads, no name lookup)"
    return true
  gOpticChainState = "refused: CameraManager::get_Instance did not verify, " &
                     "so there is nothing to walk from"
  result = false

proc opticFieldOfView(): float =
  ## The optic camera's live vertical FOV, or 0 when there is no optic camera
  ## -- which `zoomSensFor` reads as "unmagnified" and answers accordingly.
  ##
  ## NOTE the ambiguity this cannot resolve on its own: 0.0 means BOTH "no
  ## optic camera" and "the chain refused". The distinction is carried by
  ## `gOpticChainState`, which is reported, rather than being flattened here
  ## into a number that reads like an answer.
  result = 0.0
  if not bCamInstance.ok:
    return
  var a = noArgs()
  let cm = callPtr(bCamInstance, nullPtr(), a)
  if cm == nil:
    return
  let container = guardedField(cm, OffCamManagerOptic, "OpticCameraManager")
  if container == nil:
    return
  let cam = guardedField(container, OffOpticCamera, "OpticCameraManager.Camera")
  if cam == nil:
    return
  var none = noKinds()
  if not ensureCall(obCamFov, cam, "get_fieldOfView", none, fkF32):
    return
  a.reset()
  result = callFloat(obCamFov.b, cam, a)

# ---------------------------------------------------------------------------
# Effect 1: the per-frame FOV write
# ---------------------------------------------------------------------------

proc pollZoomKey() =
  ## Effect 5: the toggle-zoom key.
  ##
  ## Runs on the game thread, inside the game's own frame, which is the only
  ## place `UnityEngine.Input` may be read at all. No allocation: `Args` is a
  ## stack value and the KeyCode goes in as a plain integer.
  ##
  ## The three-way outcome is kept. `gZoomKeyState` says armed, refused with
  ## a reason, or not attempted, and `gZoomOn` is false in every case but
  ## the first -- so "the key is not down" and "there is no key" never
  ## collapse onto the same answer in the log.
  if gZoomKeyDirty:
    gZoomKeyDirty = false
    gZoomLatch = false
    gZoomOn = false
    gZoomKeyCode = keyCodeOrdinal(cfgZoomToggleKey)
    if gZoomKeyCode < 0:
      gZoomKeyState = "refused: \"" & cfgZoomToggleKey & "\" is not a " &
                      "member of UnityEngine.KeyCode. The 328-member map " &
                      "in this file is the output of `tools/fldoff.py enum " &
                      "UnityEngine.KeyCode`; a name that is not in it is " &
                      "not a key on this build, and is NOT read as None."
      warn "FOV: " & gZoomKeyState
    elif bGetKey.ok and bGetKeyDown.ok:
      gZoomKeyState = "armed: " & cfgZoomToggleKey & " = KeyCode " &
                      $gZoomKeyCode & ", " &
                      (if cfgHoldToZoom: "hold to zoom" else: "toggle") &
                      (if cfgCancelZoomOnUnAds: ", cancelled on un-ADS"
                       else: "")
      info "FOV: toggle zoom " & gZoomKeyState
    else:
      gZoomKeyState = "refused: " &
                      (if bGetKey.ok: bGetKeyDown.why else: bGetKey.why)
  if gZoomKeyCode < 0 or not bGetKey.ok or not bGetKeyDown.ok:
    gZoomOn = false
    return
  let now = perfCounter()
  if gLastKeyTicks != 0'i64 and
     nanosBetween(gLastKeyTicks, now) < KeyIntervalNs:
    return
  gLastKeyTicks = now
  var a = noArgs()
  addInt(a, int64(gZoomKeyCode))
  if cfgHoldToZoom:
    gZoomOn = callBool(bGetKey, nullPtr(), a)
    return
  if callBool(bGetKeyDown, nullPtr(), a):
    gZoomLatch = not gZoomLatch
  # `cancelZoomOnUnAds` reads the PREVIOUS write's aiming state, because
  # this poll deliberately runs ahead of the frame that computes the next
  # one. One frame of lag, on a latch that only ever clears; said here
  # rather than hidden. It defaults off, so the default path does not
  # depend on it at all.
  if cfgCancelZoomOnUnAds and not gLastAiming:
    gZoomLatch = false
  gZoomOn = gZoomLatch

proc applyFov() =
  ## Upstream's `FovController.Update`, on the fast path.
  ##
  ## Runs inside a patched game method, so it is on the game thread and inside
  ## the game's own frame -- which is where a Unity write has to happen. Every
  ## pointer here is resolved fresh and dropped before the call returns: rule 4
  ## in docs/PERF.md, and the reason nothing in this file stores one.
  if not cfgEnableFovWrite:
    return
  if not bCamInstance.ok or not bSetFov.ok:
    return
  # BEFORE the rate gate: GetKeyDown is a one-frame edge and the gate below
  # skips frames by design. pollZoomKey has its own, tighter gate.
  pollZoomKey()
  let now = perfCounter()
  if gLastFovTicks != 0'i64 and
     nanosBetween(gLastFovTicks, now) < FovIntervalNs:
    return
  gLastFovTicks = now
  let measuring = gFovSamples < CostSamples

  let firstPass = gFovWrites == 0'i64 and not gFovBoundSaid
  if firstPass: bc "A1 applyFov: past the rate gate"
  var none = noKinds()
  var a = noArgs()
  # The world, from the host's cache rather than from a type probe. `gwWorld`
  # returns nil for states 0, 1 and 2 alike -- and states 0 and 1 are
  # INCONCLUSIVE, not "no raid". A silent nil here must therefore never be
  # read as "not in a raid", which is why `onWorldReady` and `reportWatch`
  # both print `gwStateText()`: the three-way answer stays visible even
  # though this fast path can only branch two ways.
  if firstPass: bc "A2 about to ask the host export for the world"
  let w = gwWorld()
  if w == nil:
    if firstPass: bc "A2x no world (host export state below 3) -- returning"
    return
  if not fovReadable(w, 16):
    if firstPass: bc "A2y world pointer not readable -- returning"
    return
  if firstPass: bc "A3 world in hand and readable"

  if firstPass: bc "A4 about to bindOnObject get_MainPlayer on the world"
  if not ensureCall(obMainPlayer, w, "get_MainPlayer", none, fkPtr):
    gFovState = "refused: " & obMainPlayer.why
    return
  a.reset()
  if firstPass: bc "A5 get_MainPlayer bound; about to CALL it"
  let player = callPtr(obMainPlayer.b, w, a)
  if player == nil: return
  if firstPass: bc "A6 player in hand"

  if not ensureCall(obPwa, player, "get_ProceduralWeaponAnimation", none,
                    fkPtr):
    gFovState = "refused: " & obPwa.why
    return
  a.reset()
  let pwa = callPtr(obPwa.b, player, a)
  if pwa == nil: return
  if firstPass: bc "A7 weapon animation in hand"

  a.reset()
  # SUSPECT (a). The first execution EVER of a verified-but-never-run RVA.
  if firstPass: bc "B1 about to CALL CameraManager::get_Instance @0x1263bd0"
  let cm = callPtr(bCamInstance, nullPtr(), a)
  if firstPass: bc "B2 get_Instance returned without faulting"
  if cm == nil:
    if firstPass: bc "B2x get_Instance returned NULL -- returning"
    return
  # SUSPECT (c). A CameraManager that is non-null but not yet initialised.
  if not fovReadable(cm, OffCamManagerCamera + 8):
    if firstPass: bc "B2y CameraManager not readable to +0x78 -- returning"
    return
  # `get_Camera` is not called: it resolves to 0x65ED10, which is literally
  # `mov rax,[rcx+0x70]; ret` and is a FOLDED body shared with every other
  # `+0x70` reference getter in the build. The field read is the same answer
  # with one fewer call and no shared-RVA exposure. Offset from
  # `tools/fldoff.py`: CameraManager.<Camera>k__BackingField @0x70.
  let cam = guardedField(cm, OffCamManagerCamera, "CameraManager.Camera")
  if cam == nil:
    if firstPass: bc "B3x CameraManager.Camera is null -- returning"
    return
  if firstPass: bc "B3 camera in hand"

  if firstPass: bc "B4 about to bindOnObject get_fieldOfView on the camera"
  if not ensureCall(obCamFov, cam, "get_fieldOfView", none, fkF32):
    gFovState = "refused: " & obCamFov.why
    return
  if firstPass: bc "B5 get_fieldOfView bound"

  if not gFovBoundSaid:
    gFovBoundSaid = true
    gFovState = "armed, SetFov taking " & $gSetFovArgc &
                " argument(s) at the verified RVA 0x" & hexs(RvaSetFov3)
    info "FOV: the per-frame chain bound -- " & gFovState

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
    info "FOV: base field of view captured at " & $gBaseFov

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

  gLastAiming = aiming

  var mult = 1.0
  if aiming:
    mult = (if optic: cfgOpticFovMulti else: cfgNonOpticFovMulti)
  if gZoomOn:
    # Upstream applies the toggle-zoom multiplier ON TOP of the aim
    # multiplier, and picks the unaimed one when the player is not aiming.
    if aiming:
      mult = mult * (if optic: cfgOpticToggleZoomMulti
                     else: cfgNonOpticToggleZoomMulti)
    else:
      mult = mult * cfgUnaimedToggleZoomMulti
    gZoomFrames = gZoomFrames + 1

  let target = gBaseFov * mult
  a.reset()
  addFloat(a, target)
  if gSetFovArgc == 3:
    addFloat(a, 0.0)     # lerp time: upstream sets the value outright
    addBool(a, true)
  # SUSPECT (a), the other half.
  if firstPass: bc "C1 about to CALL CameraManager::SetFov @0x1268d20"
  callVoid(bSetFov, cm, a)
  if firstPass: bc "C2 SetFov returned without faulting"
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
    gScaleState = "REFUSED (INCONCLUSIVE, not absent): confirming the signature of " &
                  TyPlayer & "::CalculateScaleValueByFov" & " needs a by-name IL2CPP " &
                  "lookup, and this build's IL2CPP exports are " &
                  "TOKEN-GATED: 38 of 241 take a trailing 32-byte token we " &
                  "do not pass, and on mismatch they return a uniform " &
                  "random non-zero uint64 from a per-thread MT19937-64. So " &
                  "the handle is garbage, the nil check passes, and the " &
                  "first dereference kills the process. This " &
                  "effect is NOT ported to a verified static RVA yet; " &
                  "it needs one from tools/il2cpp_resolve.py plus a " &
                  "PatchKind the host can install by address."
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
    gSensState = "REFUSED (INCONCLUSIVE, not absent): confirming the signature of " &
                  TySight & "::get_GetCurrentSensitivity" & " needs a by-name IL2CPP " &
                  "lookup, and this build's IL2CPP exports are " &
                  "TOKEN-GATED: 38 of 241 take a trailing 32-byte token we " &
                  "do not pass, and on mismatch they return a uniform " &
                  "random non-zero uint64 from a per-thread MT19937-64. So " &
                  "the handle is garbage, the nil check passes, and the " &
                  "first dereference kills the process. This " &
                  "effect is NOT ported to a verified static RVA yet; " &
                  "it needs one from tools/il2cpp_resolve.py plus a " &
                  "PatchKind the host can install by address."
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
    gAimSensState = "REFUSED (INCONCLUSIVE, not absent): confirming the signature of " &
                  TyFirearm & "::get_AimingSensitivity" & " needs a by-name IL2CPP " &
                  "lookup, and this build's IL2CPP exports are " &
                  "TOKEN-GATED: 38 of 241 take a trailing 32-byte token we " &
                  "do not pass, and on mismatch they return a uniform " &
                  "random non-zero uint64 from a per-thread MT19937-64. So " &
                  "the handle is garbage, the nil check passes, and the " &
                  "first dereference kills the process. This " &
                  "effect is NOT ported to a verified static RVA yet; " &
                  "it needs one from tools/il2cpp_resolve.py plus a " &
                  "PatchKind the host can install by address."
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
  # A SECOND, CODE-LEVEL gate, because the first one was a config value and a
  # config value can be overridden by a file we did not ship. This one
  # cannot: there is no key that turns it off.
  #
  # `hook` -> `patch` asks the host to detour a method BY NAME. That is the
  # route the token-gated export ABI makes fatal, and these calls exist
  # PURELY TO COUNT FIRINGS. A diagnostic must not be able to kill the
  # process it is diagnosing.
  if side() == sideClient:
    bc("V* watch DECLINED (never patched): " & target)
    warn "not watching " & target & " -- by-name host detours are refused " &
         "in the client outright. This is a counter, and a counter must not " &
         "be able to kill the client."
    shrink(gWatchNames, gWatchNames.len - 1)
    shrink(gWatchCounts, gWatchCounts.len - 1)
    return
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
  if gDriverFirings == 1:
    # The first tick ONLY. This is suspect (a) on the coordinator's list: the
    # RVAs are prologue-verified but have never been EXECUTED, and a verified
    # prologue proves the bytes match, not that calling them here is legal.
    # If the run dies with T1 present and T2 absent, the fault is inside
    # `applyFov` on its first pass and the sub-crumbs A*/B* say where.
    bc "T1 first everyMain tick, about to call applyFov"
  gDriverThreadId = currentThreadId()
  applyFov()
  if gDriverFirings == 1:
    bc "T2 first everyMain tick returned from applyFov"
  result = ""

proc armFovDriver() =
  ## Install whatever will call `applyFov` every frame.
  bc "D1 armFovDriver entered"
  if not cfgEnableFovWrite:
    # Nothing is installed AT ALL -- not a driver that calls a chain that
    # returns at its first guard, which would still be a per-frame call into
    # code whose safety is the open question. No callback is registered, so
    # `applyFov` is unreachable for the whole run.
    gDriverState = "NOT INSTALLED: enableFovWrite is off (the default). No " &
                   "driver was registered and applyFov is unreachable this " &
                   "run. The two static RVAs are still verified and reported " &
                   "above; what is not proven is that CALLING them from the " &
                   "host's everyMain drain is survivable, and the client is " &
                   "still dying at ~9.7s with this mod staged."
    gFovState = "NOT INSTALLED: enableFovWrite is off (the default)"
    bc "D2 armFovDriver declined (enableFovWrite off)"
    return
  if not bCamInstance.ok or not bSetFov.ok or
     gFovState.substr(0, 5) != "arming":
    # The statics, *and* the SetFov arity check that follows them. A driver
    # armed over a refused chain is a per-frame call that returns at its first
    # guard for the rest of the session, and a log line saying the write is
    # driven.
    gDriverState = "refused: the FOV chain did not arm (" & gFovState &
                   "), so a driver would run a chain that refuses per frame"
    return
  # THE DETOUR PATH IS DEFAULT-OFF, and that is a safety decision rather
  # than a preference.
  #
  # `hook` -> `patch` asks the host to detour a method BY NAME. On this build
  # a by-name route is fatal the moment it is USED rather than resolved (the
  # fact this whole file was rewritten for), and 28.3% of by-name lookups
  # land on a SHARED RVA -- 6,261 RVAs have more than one owner -- where a
  # detour fires for every method that shares it, which is a write with
  # unbounded blast radius. `EFT.Player::Look`'s sharedness has NOT been
  # checked here; until somebody checks it with
  # `il2cpp_resolve.py type <idx> --shared`, this stays off.
  #
  # `everyMain` needs none of that: it is a host scheduler callback drained
  # from a detour the HOST already owns, so it adds no second detour to
  # anything (two detours on one function overwrite each other's trampoline)
  # and resolves no name.
  var hookWhy = "not attempted: hookFrameDriver is off by default -- see " &
                "armFovDriver"
  if cfgHookFrameDriver:
    if hook(FrameDriver, onWatched) == Ok:
      gDriverState = "armed on the " & FrameDriver & " detour, which is a " &
                     "game method and therefore the game's own thread"
      return
    hookWhy = lastError()
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
  # Suspect 4 from the coordinator: a by-name resolve that merely RECORDS a
  # garbage handle would not fault at the resolve, it would fault at the
  # first DEREFERENCE. So crumb each of the seven individually. If a run dies
  # between two Y-crumbs, the resolve IS the faulting statement; if it clears
  # all seven, nothing downstream dereferences what they produced -- and
  # nothing does, because a `GameType` here is only ever asked `available()`
  # and none of the seven values is read anywhere else in this file.
  bc("Y* about to resolve " & t.name)
  if t.available():
    info "  resolved " & t.name
  else:
    warn "  NOT FOUND: " & t.name & " -- a rename would show up here first"

proc onWorldReady() =
  ## Misnamed by inheritance and kept only because the call sites read that
  ## way; it means "the host's Unity-thread drain has fired", nothing more.
  ##
  ## It USED to open with `success "FOV: the game world is up"`, which
  ## was false on every run that ever printed it -- the gate behind it was a
  ## type-existence probe. The honest state goes out instead, three-valued,
  ## and it is INFO not SUCCESS because arming is not an achievement.
  bc "W1 onWorldReady entered"
  info "FOV: crash-proof breadcrumbs are being written to " & bcWhere() &
       " (absolute, resolved by GetFullPathName -- read THAT file, not the " &
       "host log, if the client dies: the host log has been measured to " &
       "lose about six statements of tail on a hard crash)"
  info "FOV: arming on Unity's thread. World: " & gwStateText()
  bc "W2 gwStateText survived (host export queried)"

  # Every type FOV Fix patched. Resolving them is not decorative: if BSG or a
  # backport renames one, this is the line that says so, and it says it before
  # anything downstream fails in a way that reads like a different bug.
  bc "W3 about to resolve seven game types by name (the HOST route)"
  reportType(CameraManager)
  reportType(ProceduralWeaponAnimation)
  reportType(Player)
  reportType(FirearmController)
  reportType(SightComponent)
  reportType(GameSettingsTab)
  reportType(ScopeZoomHandler)
  bc "W4 seven game types resolved"

  # Binding happens here rather than in `onLoad`, and that is not a detail:
  # `findClass` walks every loaded assembly, and at load time the game's own
  # assemblies are not among them, so a binding made then would correctly
  # refuse and never be retried.
  bc "W5 about to openRuntime"
  if not openRuntime():
    gFovState = "refused: the IL2CPP runtime could not be bound from the mod"
    gScaleState = gFovState
    gSensState = gFovState
    gAimSensState = gFovState
    warn "FOV: " & gFovState
  else:
    bc "W6 openRuntime ok; about to bindFovStatics"
    discard bindFovStatics()
    bc "W7 bindFovStatics returned"
    armScaleFix()
    bc "W8 armScaleFix returned"
    armScopeSensitivity()
    bc "W9 armScopeSensitivity returned"
    armAimingSensitivity()
    bc "W10 armAimingSensitivity returned"

  # The driver goes in before the diagnostics, because it is the effect and
  # they are the measurement. It used to go in after, inside the `verifyHooks`
  # block, which meant one config flag switched off the mod.
  bc "W11 about to armFovDriver"
  armFovDriver()
  bc "W12 armFovDriver returned"

  info "FOV: static RVAs -- " & $gRvaVerified & " prologue-verified, " &
       $gRvaRejected & " REFUSED; by-name lookups declined in the client: " &
       $gByNameRefusals
  info "FOV: per-frame FOV write -- " & gFovState
  info "FOV:   driven by -- " & gDriverState
  info "FOV:   optic chain -- " & gOpticChainState
  info "FOV: CalculateScaleValueByFov -- " & gScaleState
  info "FOV: scope sensitivity -- " & gSensState
  info "FOV: aiming sensitivity -- " & gAimSensState
  # The 9.703s run's host log ENDS here -- but the next statement is an
  # unconditional `info` that never appeared. E1 is the crumb that settles
  # whether the log tail was lost or the process really stopped here.
  bc "E1 summary dump complete"
  # THE VALUE IN FORCE, not the default in the source. The 8.328s death was
  # localised to exactly this: a flag whose source default said false while
  # the deployed config.json said true. Crumb what `cfgBool` actually
  # returned, so the two can never be conflated again.
  bc("E1a flags in force: verifyHooksByName=" & $cfgVerifyHooks &
     " enableFovWrite=" & $cfgEnableFovWrite &
     " hookFrameDriver=" & $cfgHookFrameDriver &
     " deferUntilUnityThread=" & $cfgDeferUntilUnityThread &
     " (retired key verifyHooks on disk=" & $gStaleVerifyHooks & ")")
  if gStaleVerifyHooks:
    warn "the deployed config.json still has \"verifyHooks\" in it. That " &
         "key is RETIRED and is no longer read -- it is replaced by " &
         "\"verifyHooksByName\", which defaults OFF. Left as-is it does " &
         "nothing; delete it to keep the file honest."

  if not cfgVerifyHooks:
    info "verifyHooksByName is off; not attaching the target-verification " &
         "detours."
    bc "E2 verifyHooksByName off -- onWorldReady returning, nothing patched"
    return
  bc "E3 verifyHooksByName is ON -- entering the by-name watch block"

  # The exact methods the original patched, in the original's order. Sixteen
  # patch slots exist; this uses six, two of which now do work rather than
  # only counting.
  bc "G1 about to watch PWA::UpdateWeaponVariables"
  watch("EFT.Animations.ProceduralWeaponAnimation::UpdateWeaponVariables",
        "PwaWeaponParamsPatch -- where upstream learns the current weapon")
  bc "G2 PWA::UpdateWeaponVariables watch returned"
  bc "G3 about to watch PWA::LerpCamera"
  watch("EFT.Animations.ProceduralWeaponAnimation::LerpCamera",
        "LerpCameraPatch -- not ported: the camera-offset field names cannot " &
        "be confirmed against a running build. The cost objection this line " &
        "used to carry (\"reaching `this` costs ~1 us per frame\") expired " &
        "with ABI revision 3")
  # Counted, not hooked again: `armFovDriver` already detoured this when it
  # took the first of its two paths, and on the `everyMain` path there is no
  # detour on it to count.
  bc "G4 LerpCamera watch returned; on to the driver target"
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
  bc "G5 driver target handled; on to CalculateScaleValueByFov"
  if armed(gScaleState):
    info "watching EFT.Player::CalculateScaleValueByFov through the " &
         "replacing hook (CalculateScaleValueByFovPatch)"
  else:
    watch("EFT.Player::CalculateScaleValueByFov",
          "CalculateScaleValueByFovPatch -- viewmodel/ribcage scale")
  bc "G6 on to get_AimingSensitivity"
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
  bc "G7 watch block complete -- onWorldReady falling off the end"

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
    info "FOV target verification, after roughly a minute in raid:"
    for i in 0 ..< gWatchNames.len:
      if gWatchCounts[i] > 0:
        success "  " & gWatchNames[i] & " fired " & $gWatchCounts[i] & " times"
      else:
        warn "  " & gWatchNames[i] & " never fired -- it is patched but the " &
             "game does not call it; treat the name as stale"
  info "FOV, what was actually applied:"
  # The world state goes FIRST, because it is the thing that decides whether
  # a zero write count means "broken" or "you were in the menu". A zero with
  # state 0 or 1 is INCONCLUSIVE and says so; a zero with state 3 is a real
  # failure.
  info "    world: " & gwStateText()
  info "    static RVAs: " & $gRvaVerified & " verified, " & $gRvaRejected &
       " REFUSED; by-name lookups declined: " & $gByNameRefusals
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
       "8 ns, and bindRaw reaches a Vector3) -- and the NAME objection has " &
       "expired as well, because fldoff.py prints " &
       "ProceduralWeaponAnimation's whole field list offline; what is left " &
       "for LerpCamera is that upstream's patch is not vendored, so its " &
       "BEHAVIOUR would be the guess. The FOV slider range is NOT the same " &
       "kind of problem and is no longer a 'not yet': measured, the bounds " &
       "are C# consts (GameSettingsGroup.MIN/MAX_FIELD_OF_VIEW, attrs " &
       "0x8056 = LITERAL), inlined with no storage, so there is nothing to " &
       "write. The toggle-zoom key " &
       "needs a KeyCode ordinal this port will not guess -- measured: the " &
       "ordinals live in a metadata blob that does not decode here -- and " &
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
  if side() == sideClient:
    # Same belt and braces: this proc calls `findClass` and `bindMethod`
    # directly. It is only ever invoked from `simSelfTest`, which `onLoad`
    # runs on `sideSim` alone -- but the guard is here rather than only
    # there.
    warn "  guards not checked: they use by-name IL2CPP resolution, which " &
         "is fatal in the client (token-gated exports). Run the self-test " &
         "on the sim " &
         "side against selfTestRuntime instead."
    return
  if not rtOpen:
    warn "  guards not checked: no runtime is bound, so there is nothing to " &
         "ask. Set selfTestRuntime to exercise them."
    return
  if gNoDomain:
    warn "  guards not checked: the runtime loaded but il2cpp_init gave no " &
         "domain, so a by-name lookup would walk structures that were never " &
         "built -- measured to be a 0xC0000005, not a nil."
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
  info "FOV self-test (--side sim)"

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
        # Recorded, not just announced. The old message went on to promise
        # that "every binding below will refuse with 'no such type'" -- and
        # MEASURED 2026-08-26 against the real
        # D:\Games\Tarkov\GameAssembly.dll, they do not refuse: the first
        # by-name probe takes the whole sim down with 0xC0000005. A domain
        # that `il2cpp_init` declined to build is not an empty universe, it
        # is an absent one, and walking it is the same class of fault as
        # fault as the token-gated exports in the client.
        gNoDomain = true
        warn "  " & runtimePath & " loaded but il2cpp_init returned no " &
             "domain. That is the expected answer for a real client out of " &
             "process -- the metadata is decrypted during the game's own " &
             "startup. Every BY-NAME lookup below is therefore SKIPPED, not " &
             "attempted: measured, attempting one is an access violation, " &
             "not a nil. The verified static RVAs below are unaffected and " &
             "still checked, because they read bytes rather than metadata."
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
  info "    GameWorld::get_Instance -- NOT BOUND, and never will be: it " &
       "does not exist on this build (409 members, zero matches). The world " &
       "comes from the host export aowl_host_gameworld: " & gwStateText()
  probeMember(TyGameWorld, "get_MainPlayer", 0)
  probeMember(TyPlayer, "get_ProceduralWeaponAnimation", 0)
  reportBinding("CameraManager::get_Instance (verified static RVA)",
                bCamInstance)
  reportBinding("CameraManager::SetFov (verified static RVA)", bSetFov)
  reportBinding("Input::GetKey (verified static RVA)", bGetKey)
  reportBinding("Input::GetKeyDown (verified static RVA)", bGetKeyDown)
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
    info "  " & gOpticChainState
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
       "The NAME objection has expired too: fldoff.py prints the whole " &
       "ProceduralWeaponAnimation field list offline -- _cameraByFOVOffset " &
       "@0x1e0, RotationCameraOffset @0x18c, _vCameraTarget @0x180, Offset " &
       "@0x98, CameraSmoothTime @0x124, vel @0x128. What is left is that " &
       "upstream's LerpCameraPatch is not vendored beside this file, so which " &
       "of those it writes and how is a guess about BEHAVIOUR, which is worse " &
       "than a guess about a name. Refused."
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
  info "    the toggle-zoom key -- **ported**. The old refusal here quoted a " &
       "real measurement (KeyCode.None decoding as -25161728) and drew the " &
       "wrong conclusion from it: metadata property 8 is NOT encrypted, it " &
       "stores I4/U4 as ECMA-335 compressed integers, big-endian and " &
       "zigzagged, so a four-raw-byte read at None swallowed three " &
       "constants. `tools/fldoff.py enum UnityEngine.KeyCode` decodes all " &
       "328 members and `il2cpp_resolve.py verify-consts` checks the decoder " &
       "against 19 known values. Input::GetKey @0x531EAE0 / GetKeyDown " &
       "@0x531EB80, both static, both prologue-verified at bind."
  info "    toggle zoom state: " & gZoomKeyState & " -- writes taken with " &
       "zoom asserted: " & $gZoomFrames
  info "    the base-FOV slider range -- MEASURED and now a hard NO, not a " &
       "'not yet'. GameSettingsTab has 34 fields on this build and no FOV " &
       "bound among them; the bounds are GameSettingsGroup.MIN_FIELD_OF_VIEW " &
       "/ MAX_FIELD_OF_VIEW, both attrs 0x8056 = FIELD_ATTRIBUTE_LITERAL. A " &
       "C# const has no storage and is inlined at every use site: there is " &
       "no field to write and no getter to detour."

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
  # THE VALUES IN FORCE, at load, on every side. Not the defaults in this
  # source file -- `cfgBool` reads the DEPLOYED config.json, and the 8.328s
  # death was exactly that gap: `verifyHooks` defaulted false here and was
  # true on disk, so the gate that was supposed to stop the by-name detours
  # never closed. A default is not a value. Print the value.
  info "FOV flags IN FORCE (read from the deployed config.json, not the " &
       "source defaults): enableFovWrite=" & $cfgEnableFovWrite &
       " verifyHooksByName=" & $cfgVerifyHooks &
       " hookFrameDriver=" & $cfgHookFrameDriver &
       " deferUntilUnityThread=" & $cfgDeferUntilUnityThread &
       " enableFovScaleFix=" & $cfgEnableFovScaleFix
  if gStaleVerifyHooks:
    warn "the deployed config.json still carries \"verifyHooks\". That key " &
         "is RETIRED and is NOT read any more: it was renamed to " &
         "\"verifyHooksByName\" precisely because a stale true on disk " &
         "silently overrode the new default and killed the client at 8.328s. " &
         "It now does nothing. Delete it to keep the file honest."
  declareSettings(fovSchema())
  discard serve("/aowlspt/settings/" & ModGuid, onFovSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onFovSettingsReset)
  success ModName & " " & ModVersion & " loaded on " & hostName()
  if side() == sideSim:
    return simSelfTest()
  if side() != sideClient:
    info "FOV is client-only; nothing to do on this side"
    return Ok

  info "config: optic FOV x" & $cfgOpticFovMulti & ", unmagnified x" &
       $cfgNonOpticFovMulti & ", base FOV range " & $cfgMinBaseFov & ".." &
       $cfgMaxBaseFov
  info "config: toggle zoom on " & cfgZoomToggleKey &
       " (KeyCode " &
       (if keyCodeOrdinal(cfgZoomToggleKey) < 0: "UNKNOWN -- refused"
        else: $keyCodeOrdinal(cfgZoomToggleKey)) & ")" &
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

## Deferral state. See `onUpdate`.
var gPending = false
var gPendingMs = 0'i64
var gPollMs = 0'i64
var gDeferSaid = false

proc onUpdate(elapsedMs: int64): Status =
  if side() != sideClient:
    return Ok
  gElapsedMs = gElapsedMs + elapsedMs

  # `world.ready()` is a TYPE-existence probe, and the name has been lying.
  # `EFT.GameWorld` is a type in `Assembly-CSharp.dll`, so it resolves the
  # instant the IL2CPP runtime is up -- MEASURED at 1.375s into a run, with no
  # world, no player, no camera and no scene. Everything `onWorldReady` does
  # therefore used to run a quarter of a second after `host running`, on the
  # host's own thread, while the client was still booting.
  #
  # So the probe is kept (it is the cheap "the runtime is up" signal it always
  # really was) and a second, honest gate is put in front of the work: the
  # host's own answer to whether its main-thread drain has FIRED. That is the
  # only evidence available from inside a mod that Unity's thread is live, and
  # in a surviving run it does not become true until 14.469s.
  #
  # This is the standing hypothesis for the crash, stated so it can be
  # falsified: if a run with `deferUntilUnityThread` on still dies at ~1.4s in
  # `openRuntime`, the thread was never the cause and the breadcrumbs there say
  # which sub-step it was instead.
  if world.ready():
    if not cfgDeferUntilUnityThread:
      info "FOV: deferUntilUnityThread is off; arming immediately on the " &
           "host's own thread, which is what the 2026-08-25 crash did"
      onWorldReady()
      gElapsedMs = 0
    else:
      gPending = true
      gPendingMs = 0
      gPollMs = 0

  if gPending:
    gPendingMs = gPendingMs + elapsedMs
    gPollMs = gPollMs + elapsedMs
    # Throttled: asking the host every frame is a host round trip per frame for
    # no new information, and the answer changes at most once.
    if gPollMs >= DeferPollMs:
      gPollMs = 0
      let mt = askMainThread()
      if mt.ok and mt.bound:
        gPending = false
        bc "U1 host drain confirmed; about to call onWorldReady"
        success "FOV: Unity's main thread is live after " &
                $(gPendingMs div 1000) & "s (drain " & mt.methodName & ", " &
                $mt.frames & " firings); arming now"
        onWorldReady()
        bc "U2 onWorldReady RETURNED -- arming complete and survived"
        gElapsedMs = 0
      elif gPendingMs >= DeferGiveUpMs:
        # Self-disable rather than arm anyway. Arming here would be doing
        # exactly the thing this gate exists to prevent, and doing it after
        # announcing that the evidence for its safety never arrived.
        gPending = false
        gFovState = "refused: the host's main-thread drain never confirmed " &
                    "within " & $(DeferGiveUpMs div 1000) & "s, so there is " &
                    "no thread on which a camera write is legal"
        gScaleState = gFovState
        gSensState = gFovState
        gAimSensState = gFovState
        gDriverState = gFovState
        warn "FOV: " & gFovState & " -- this mod has switched itself OFF " &
             "for the rest of the run. Nothing was patched."
      elif not gDeferSaid and gPendingMs >= 3000:
        gDeferSaid = true
        info "FOV: the runtime is up but the host's main-thread drain has " &
             "not fired yet; holding every hook until it does (up to " &
             $(DeferGiveUpMs div 1000) & "s)"
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
