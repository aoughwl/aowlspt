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
## **DEFAULTS AS SHIPPED (batch-fov-cheap, on integ-beta-batch).** Write 1 -- the
## per-frame FOV write -- is now ON by default (`enableFovWrite = true`) and is
## the FOV widening the player sees. It is driven off the mouse-look path: its
## driver is the host's `everyMain` drain (once per frame on Unity's thread), NOT
## a detour on `EFT.Player::Look`, and `hookFrameDriver` stays OFF, so the FOV
## effect costs nothing per mouse-look. It does not depend on `enableRvaDetours`.
## `nonOpticFovMulti` ships at 1.25 so the effect is visible on iron/reflex ADS;
## `opticFovMulti` stays 1.0 so magnified scopes are left alone. Writes 2 and 3
## are by-RVA TYPED detours gated behind `enableRvaDetours` (still OFF). Write 3
## -- the sensitivity table -- and the aiming-sensitivity postfix are ADDITIONALLY
## gated OFF by `changeMouseSensitivity = false`, because they detour the
## per-mouse-look getters `get_GetCurrentSensitivity` (@0x104A140) and
## `get_AimingSensitivity` (@0x7773F0) -- exactly the hot path that made the game
## "super laggy until the mouse settled". Write 2
## (`CalculateScaleValueByFov`, @il2cpp+0x6FC250) fires on ADS/state-change, NOT
## per mouse-look, so it is the safe one to turn on with `enableRvaDetours`. The
## write path self-disables after a fault storm (see `onFovTick`).
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
var cfgEnableRvaDetours = false
  ## MASTER GATE for the three by-RVA typed detours that replace the fatal
  ## by-name (`signatureOf` + name-target) path for the scale/scope/aim effects.
  ## DEFAULT OFF (host-safety rule 5): even with `changeMouseSensitivity` or
  ## `enableFovScaleFix` on, NOTHING is detoured into the live client until this
  ## is turned on deliberately. The install itself is fully guarded by the host
  ## (prologue byte-verify against the startup snapshot, VirtualQuery, il2cpp
  ## section check, sharedness), so the worst case with it off-by-default is a
  ## logged refusal -- never a fault. Turn on per-effect flag AND this to arm.
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

var cfgEnableAdsSmoothing = true
  ## Interpolate the field of view between the hip target and the ADS target
  ## instead of snapping. The user-visible complaint this exists for was "it
  ## should smoothly change the FOV when I ADS": before this, `applyFov`
  ## computed a multiplier and wrote `base * mult` outright, so the transition
  ## was a single-frame step.
var cfgAdsSmoothTime = 0.16
  ## Seconds for the hip -> ADS/zoom transition, when the aim speeds are not
  ## driving it. A DURATION, not a lerp coefficient: the value reaches its
  ## target at a stated time, which is what makes the PASS/FAIL/INCONCLUSIVE
  ## transition verdict below expressible at all. An asymptotic
  ## `lerp(cur, target, k)` never arrives and so can never be asserted.
var cfgUnAdsSmoothTime = 0.12
  ## Seconds for the ADS/zoom -> hip transition.
var cfgUseAimSpeedsForFov = true
  ## Take the two durations from `rifleAimSpeedZ` / `unAimSpeedZ` instead of
  ## from the two settings above: duration = 1 / speed. Upstream's aim speeds
  ## are `Lerp(a, b, speed * dt)` rates on the camera offset vector, so 1/speed
  ## is that lerp's time constant; the mapping is STATED here and printed at
  ## load rather than being an unexplained coincidence of units. Z is the axis
  ## used because Z is the forward/zoom axis. The X and Y speeds, and all three
  ## pistol speeds, stay INERT: nothing in this mod reads the weapon class, so
  ## choosing between the rifle and pistol tables would be a guess.
var cfgAdsDeferToGame = true
  ## THE FIX for "ADS zoom-in smoothing is wrong, then at the end the FOV gets
  ## set to its real ADS FOV".
  ##
  ## The game drives its OWN field of view while aiming in, along its own curve,
  ## to a value that depends on the SIGHT. Our smoother was driving a second,
  ## different curve to `gBaseFov * mult` at the same time, from
  ## `TarkovApplication::Update`, every frame. Two writers on one field with two
  ## different endpoints is exactly the reported symptom: the rendered FOV
  ## alternates between the two curves for the length of the transition (which
  ## reads as the "grass goes into warp speed" judder), and then the moment our
  ## ramp stops changing the game's value is the only one still moving, which
  ## reads as a SNAP to the real ADS FOV.
  ##
  ## Note the asymmetry the player reported and which this explains: un-ADS is
  ## FINE. On the way out our endpoint is `gBaseFov`, which IS the game's hip
  ## FOV, so both writers agree on the destination and the fight is invisible.
  ## On the way in the game's endpoint is sight-dependent and ours is not.
  ##
  ## So: on the way in, DO NOT WRITE AT ALL. Let the game run its own ramp,
  ## watch it, and only once it has SETTLED take that settled value as the true
  ## ADS FOV and apply our multiplier to it. One writer at a time, and our
  ## multiplier composes onto the game's real ADS FOV instead of onto the hip
  ## FOV -- which is also the reason `opticFovMulti` never behaved: `base * 1.38`
  ## has nothing to do with a scope's actual magnification.
var cfgAdsWriteFovField = true
var cfgAdsHoldEveryFrame = true   ## re-assert the ADS endpoint every frame (see the hold)
  ## Write the endpoint into EFT.CameraControl.CameraManager._fov (a plain
  ## float at +0xF8, from fieldOffsets) as well as into Camera.fieldOfView --
  ## i.e. change the game's own INPUT rather than correcting its output. This
  ## is what the 40-sample probe pointed at: nothing writes Camera.fieldOfView
  ## per frame, so the snap-back seen earlier was a convergence provoked by our
  ## write disagreeing with _fov. A field write, not a detour: no RVA row, no
  ## trampoline, nothing for another feature to collide with.
var cfgAdsMaxFights = 3
  ## After this many consecutive ADS-in transitions whose endpoint did NOT
  ## survive a frame, STOP WRITING THE FIELD OF VIEW WHILE AIMING, entirely,
  ## for the rest of the run. Rule 6, and the standing judgement that a feature
  ## which visibly fights the game is worse than one that declines: the player
  ## sees "adsing gives me a smoothing, then jumps in and out, then finally in
  ## again", which is what losing a per-frame tug-of-war looks like. Declining
  ## leaves the hip field of view -- the part that works -- working.
var cfgAdsSettleEps = 0.05
  ## Degrees. Two consecutive samples of the game's own FOV closer than this
  ## count as "not moving".
var cfgAdsSettleTicks = 3
  ## How many consecutive still samples end the observation.
var cfgAdsObserveCap = 1.5
  ## Seconds. If the game's FOV has not settled by now, give up, say so, and
  ## fall back to the old base*mult endpoint rather than never applying at all.
var cfgAdsSmoothLinear = false
  ## false = smoothstep easing (p*p*(3-2p)), true = constant rate. Two curves
  ## and no `pow`, because this runs per frame and must not call into libm.

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
  # 1.25 as shipped so the FOV write has a VISIBLE effect on iron/reflex ADS by
  # default (the skip-at-1.0 gate in applyFov means a multiplier of exactly 1.0
  # never writes). Optics stay at 1.0 -- widening a magnified scope's FOV is
  # rarely wanted. Both are tunable in-game and are cosmetic, not a safety knob.
  cfgNonOpticFovMulti = cfgFloat("nonOpticFovMulti", 1.25)

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

  # DEFAULT OFF. This flag arms the two effects that detour the per-mouse-look
  # sensitivity getters (SightComponent::get_GetCurrentSensitivity @0x104A140 and
  # FirearmController::get_AimingSensitivity @0x7773F0). Even as the crash-safe
  # TYPED by-RVA detours they are now, they still FIRE on the game's hot per-look
  # call path -- the measured cause of the "super laggy, ESP frozen until the
  # mouse settles" regression. Off by default and gated separately from
  # enableRvaDetours, so the ADS-only effects can be turned on without dragging
  # the per-look ones back in.
  cfgChangeMouseSensitivity = cfgBool("changeMouseSensitivity", false)
  cfgEnableRvaDetours = cfgBool("enableRvaDetours", false)
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
  # DEFAULT ON. The per-frame FOV write is the effect this mod exists for and is
  # the FOV widening the player sees. Its whole path is de-risked: three field
  # reads at offline-derived offsets and three calls at 16-byte-prologue-verified
  # static RVAs -- no by-name lookup, so the fact-#198 crash surface is not on it
  # -- driven from the host's everyMain drain (once per frame, Unity's thread)
  # and NOT from any detour on the mouse-look path, so it costs nothing per look.
  # It is rate-gated, skips a redundant 1.0 multiplier (the cached-multiplier
  # path), and self-disables after a fault storm (onFovTick). It does NOT depend
  # on enableRvaDetours. The 9.703s startup stop noted in armFovDriver was
  # measured with THIS write OFF, so it is not attributable to this write; it is
  # UNRESOLVED and must be confirmed-or-refuted live via the breadcrumb file.
  cfgEnableFovWrite = cfgBool("enableFovWrite", true)
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

  cfgEnableAdsSmoothing = cfgBool("enableAdsSmoothing", true)
  cfgAdsSmoothTime = cfgFloat("adsSmoothTime", 0.16)
  cfgUnAdsSmoothTime = cfgFloat("unAdsSmoothTime", 0.12)
  cfgUseAimSpeedsForFov = cfgBool("useAimSpeedsForFovSmoothing", true)
  cfgAdsSmoothLinear = cfgBool("adsSmoothLinear", false)
  cfgAdsDeferToGame = cfgBool("adsDeferToGame", true)
  cfgAdsSettleEps = cfgFloat("adsSettleEps", 0.05)
  cfgAdsObserveCap = cfgFloat("adsObserveCap", 1.5)
  cfgAdsMaxFights = int(cfgFloat("adsMaxFights", 3.0))
  cfgAdsWriteFovField = cfgBool("adsWriteFovField", true)
  cfgAdsHoldEveryFrame = cfgBool("adsHoldEveryFrame", true)

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
                 lo = 0.1, hi = 2.0, step = 0.01, category = "General",
                 description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. FOV scale while aiming a magnified sight"),
    floatSetting("nonOpticFovMulti", "Non-optic FOV multiplier", 1.25,
                 lo = 0.1, hi = 2.0, step = 0.01, category = "General",
                 description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. FOV scale while aiming iron sights / reflex. Ships at 1.25 so the effect is visible by default (exactly 1.0 is skipped by applyFov as a no-op write)."),
    boolSetting("enableFovWrite", "Enable FOV write", true, category = "General",
                appliesOn = "restart",
                description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. Master switch for the per-frame FOV write -- the FOV widening you see. ON by default: the write runs at prologue-verified static RVAs over VirtualQuery'd field reads (no by-name lookup), driven from the host everyMain drain once per frame on Unity's thread -- NOT a detour on the mouse-look path, so it adds zero per-look cost, and independent of enableRvaDetours. Self-disables after a fault storm."),
    boolSetting("enableFovScaleFix", "FOV scale fix", false, category = "General",
                description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. Replace Player.CalculateScaleValueByFov with a constant"),
    floatSetting("fovScale", "FOV scale value", 1.0, lo = 0.1, hi = 3.0,
                 step = 0.01, category = "General",
      description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt."),
    intSetting("maxBaseFov", "Max base FOV", 110, lo = 30, hi = 140,
               category = "General", implemented = false,
               description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. Read only. MEASURED: the bound is the C# const GameSettingsGroup.MAX_FIELD_OF_VIEW (field attrs 0x8056 = LITERAL|STATIC|HASDEFAULT). A const has no storage and is inlined at every use site, so there is nothing to write."),
    intSetting("minBaseFov", "Min base FOV", 30, lo = 10, hi = 120,
               category = "General", implemented = false,
               description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. Read only. MEASURED: MIN_FIELD_OF_VIEW is a C# const (attrs 0x8056), same as the max -- inlined, no storage."),

    boolSetting("changeMouseSensitivity", "Scale mouse sensitivity", false,
                category = "Sensitivity", appliesOn = "restart",
                description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. OFF by default. Replaces get_GetCurrentSensitivity (@0x104A140) and scales get_AimingSensitivity (@0x7773F0) via TYPED by-RVA detours -- crash-safe, but they still FIRE on the per-mouse-look hot path and caused the 'super laggy, ESP frozen until the mouse settles' regression. Also needs enableRvaDetours. Leave off unless you have accepted that per-look cost."),
    floatSetting("oneSensMulti", "1x sensitivity", 0.75, lo = 0.0, hi = 2.0,
                 step = 0.01, category = "Sensitivity",
      description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt."),
    floatSetting("fourSensMulti", "4x sensitivity", 0.2, lo = 0.0, hi = 2.0,
                 step = 0.01, category = "Sensitivity",
      description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt."),
    floatSetting("highSensMulti", "High-mag sensitivity", 0.01, lo = 0.0,
                 hi = 2.0, step = 0.001, category = "Sensitivity",
      description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt."),

    keybindSetting("zoomToggleKey", "Toggle-zoom key", "M",
                   category = "Toggle zoom",
                   description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. Applies the toggle-zoom FOV multipliers while this key asks for zoom. The name is resolved to a UnityEngine.KeyCode ordinal from a 328-member table generated by `tools/fldoff.py enum UnityEngine.KeyCode`, then passed to Input::GetKey / GetKeyDown at their prologue-verified static RVAs. A name that is not a KeyCode member is REFUSED with the name printed -- it is never quietly read as KeyCode.None, which is a real key whose ordinal is 0."),
    boolSetting("holdToZoom", "Hold to zoom", true, category = "Toggle zoom", keybind = true,
                description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. On: zoom lasts while the key is held (Input::GetKey, a level). Off: each press toggles it (Input::GetKeyDown, an edge, latched in this mod). Both are polled ahead of the FOV rate gate, because an edge is one frame wide and that gate skips frames."),

    boolSetting("enableAdsSmoothing", "Smooth the ADS transition", true,
                category = "Field of view",
                description = "Interpolate the field of view between the hip target and the ADS target instead of stepping to it in one frame. The transition is driven by MEASURED elapsed time, so it takes the same wall-clock duration at any frame rate, and it always eases FROM WHERE THE VIEW IS -- an ADS cancelled half-way does not snap. Off reproduces the old single-frame step."),
    floatSetting("adsSmoothTime", "ADS-in time (seconds)", 0.16, lo = 0.01,
                 hi = 1.0, step = 0.01, category = "Field of view",
                 description = "How long the hip -> ADS field-of-view transition takes. IGNORED while 'Use aim speeds for FOV smoothing' is on, which is the default -- that setting takes the duration from rifleAimSpeedZ instead."),
    floatSetting("unAdsSmoothTime", "ADS-out time (seconds)", 0.12, lo = 0.01,
                 hi = 1.0, step = 0.01, category = "Field of view",
                 description = "How long the ADS -> hip field-of-view transition takes. IGNORED while 'Use aim speeds for FOV smoothing' is on, which takes it from unAimSpeedZ instead."),
    boolSetting("useAimSpeedsForFovSmoothing", "Use aim speeds for FOV smoothing",
                true, category = "Field of view",
                description = "Take the two transition durations from rifleAimSpeedZ and unAimSpeedZ as duration = 1 / speed, rather than from adsSmoothTime / unAdsSmoothTime. Upstream's aim speeds are Lerp(a, b, speed * dt) rates on the camera offset vector, so 1/speed is that lerp's time constant; Z is used because Z is the forward/zoom axis. This is the ONLY thing that reads those two settings -- the X and Y speeds and the whole pistol table are still inert, because nothing in this mod reads the weapon class and choosing a table would be a guess."),
    boolSetting("adsDeferToGame", "Let the game drive the aim-in", true,
                description = "ON (the fix for the reported ADS zoom being wrong): while aiming IN, this mod writes NOTHING and instead watches the field of view the GAME is driving. Once the game's own ramp has settled, that settled value is taken as the true ADS field of view and the multiplier is applied to it. OFF reproduces the old behaviour, where our smoothing raced the game's own aim-in along a different curve to a different endpoint -- which is what made the transition look wrong and then snap at the end. The settle test only accepts stillness AFTER it has seen the game's value actually move, so it cannot mistake 'the ramp has not started' for 'the ramp has finished'."),
    boolSetting("adsSmoothLinear", "Linear ADS easing", false,
                category = "Field of view",
                description = "Off: smoothstep easing, p*p*(3-2p) -- eases in and out, which is what reads as 'smooth'. On: constant rate. No other curves, because this runs every frame and must not call into libm."),

    floatSetting("rifleCameraZOffset", "Rifle camera Z offset", 0.025,
                 lo = -0.2, hi = 0.2, step = 0.005, category = "Camera",
                 implemented = false,
                 description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. Read only. ProceduralWeaponAnimation's field list IS now resolvable offline (tools/fldoff.py), so the old 'cannot confirm the name' reason has expired. What blocks it now is semantics: upstream's LerpCameraPatch is not vendored beside this file, so WHICH of _cameraByFOVOffset / RotationCameraOffset / _vCameraTarget it writes, and how, would be a guess about behaviour rather than about a name."),
    floatSetting("rifleAimSpeedZ", "Aim-in speed (Z)", 3.0, lo = 0.1, hi = 20.0,
                 step = 0.1, category = "Field of view",
                 description = "WIRED, as of the ADS-smoothing work: while 'Use aim speeds for FOV smoothing' is on, the hip -> ADS field-of-view transition takes 1/this seconds (3.0 = 333 ms). It does NOT drive the camera OFFSET vector -- that half is still blocked by the LerpCameraPatch semantics gap described on rifleCameraZOffset, and the X/Y and pistol speeds remain read-only for the same reason."),
    floatSetting("unAimSpeedZ", "Aim-out speed (Z)", 4.5, lo = 0.1, hi = 20.0,
                 step = 0.1, category = "Field of view",
                 description = "WIRED: while 'Use aim speeds for FOV smoothing' is on, the ADS -> hip field-of-view transition takes 1/this seconds (4.5 = 222 ms). Same caveat as the aim-in speed: it does not move the camera offset vector."),

    # The KEY is `verifyHooksByName`, not `verifyHooks`. This row used to
    # declare `verifyHooks` -- a key `loadConfig` deliberately stopped reading,
    # and which this mod WARNS about when it finds it on disk ("the deployed
    # config.json still has \"verifyHooks\" in it ... it does nothing"). So the
    # control rendered, defaulted to the opposite of the real default, wrote a
    # key nothing reads, and made the mod complain about a file the settings
    # UI had just written. Default is `false` here because that is what
    # `cfgBool("verifyHooksByName", false)` actually uses -- a schema default
    # that disagrees with the code's default is a row that lies before it is
    # ever touched.
    boolSetting("verifyHooksByName", "Verify hooks by name at load", false,
                category = "Advanced", appliesOn = "restart",
                description = "From Fontaine's FOV Fix (com.fontaine.fovfix), rewritten from scratch for aowlspt. Attach the by-name target-verification watch, which resolves each patched method by name at raid start and reports whether the live target still matches the one the detour bound. DIAGNOSTIC: it does not drive the FOV write -- that has its own driver and is armed regardless -- so leaving this off does not switch the mod off. Off by default because by-name resolution on this build can return a non-nil handle into unmapped memory")]

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

/* THE TYPED STORE PATH (docs/INTERACTION-LAYER-MAP.md M3/M6), the same route
 * mods/textures/redirect.nim uses. `aowlspt_hostwrite.h` pulls in the
 * GENERATED `aowlspt_fieldrefs.h`, which now carries
 * EFT.CameraControl.CameraManager._fov's offset, WIDTH and IS_REFERENCE
 * straight out of Il2CppMetadataRegistration.fieldOffsets. Everything it
 * declares is static, so including it costs this module nothing it does not
 * call. */
#include "aowlspt_hostwrite.h"

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

/* A float FIELD read. memcpy, not a cast through float*, so it is defined
 * behaviour at any alignment. Never called without fov_is_readable(p, off+4)
 * having said yes -- the check belongs with the pointer hop, at the caller. */
static double fov_float_at(void* p, int32_t off) {
    float v = 0.0f;
    if (!p) return 0.0;
    memcpy(&v, (const char*)p + off, sizeof(float));
    return (double)v;
}

/* fov_is_readable, plus the region must actually be WRITABLE. A readable page
 * is not a writable one, and writing a game field through a read-only mapping
 * is an access violation, not a no-op. PAGE_WRITECOPY is accepted because a
 * write through it succeeds -- privately, which for a managed heap object is
 * not what we want, so it is reported by the caller rather than trusted. */
static int32_t fov_is_writable(void* p, int32_t size) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!fov_is_readable(p, size)) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (!(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return 0;
    return 1;
}

/* A float FIELD write. Returns 1 only if the guard passed AND the value read
 * back equals what went in -- so the caller never has to assume a write took.
 * This is the whole of rule 8 in three lines: check, write, read back. */
static int32_t fov_write_float(void* p, int32_t off, double value) {
    float v = (float)value;
    float back = 0.0f;
    if (!fov_is_writable(p, off + (int32_t)sizeof(float))) return 0;
    memcpy((char*)p + off, &v, sizeof(float));
    memcpy(&back, (const char*)p + off, sizeof(float));
    return back == v ? 1 : 0;
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
proc fovFloatAt(p: Il2CppPtr; off: int32): float {.
  importc: "fov_float_at", nodecl.}
proc fovWriteFloat(p: Il2CppPtr; off: int32; value: float): int32 {.
  importc: "fov_write_float", nodecl.}

# ---------------------------------------------------------------------------
# THE TYPED STORE for CameraManager._fov.
#
# `fovWriteFloat` above is a RAW store: it takes an offset and a width this
# file chose, so this file could be wrong about both. It was the last raw store
# into game-owned memory in the tree and sat in tools/storelint.py's BASELINE
# with the reason "the field type is INFERRED in the audit from two agreeing
# instruments, not from the field table, so no FieldRef has been generated for
# it". RE-MEASURED 2026-09-04 with the System.String self-check passing:
#
#   python tools/fldoff.py fields EFT.CameraControl.CameraManager
#   0xf8  _fov  float  0x0001 private
#
# The field table DOES declare it -- the baseline's reason had simply never
# been re-checked. `python tools/fieldrefs.py print` now emits
# `CM_FOV ... off=0xf8 w=4 ref=0 instmin=0x160`, so the width and the
# is-reference bit are DERIVED here rather than being `OffCamMgrFov` restated,
# and R1 (narrow-into-reference) and the instance bound are enforced by code
# this file does not own.
#
# Bound through the GENERATED per-row accessor, never as `(&AOWL_FR_CM_FOV)`:
# `importc` on a proc emits a CALL, so that spelling compiles to
# `(&AOWL_FR_CM_FOV)()` and gcc refuses it (measured 2026-09-03, redirect.nim).
type FieldRefPtr = Il2CppPtr
proc frCmFov(): FieldRefPtr {.importc: "aowl_fr_cm_fov", nodecl.}
proc frAdmit(fr, recv: FieldRefPtr): int32 {.importc: "aowl_fr_admit", nodecl.}
proc frStoreF32(fr, recv: FieldRefPtr; sub: int32; v: float32;
                why: var int32): int32 {.importc: "aowl_fr_store_f32", nodecl.}
proc frOff(fr: FieldRefPtr): int32 {.importc: "aowl_fr_off", nodecl.}

# EFT.CameraControl.CameraManager._fov, a private float.
#
# From Il2CppMetadataRegistration.fieldOffsets via tools/fldoff.py -- NOT
# guessed, and corroborated independently: CameraManager::get_Fov @0xBBA100
# disassembles to `movss xmm0,[rcx+0xF8]; ret`. The two instruments agree.
#
# (That getter is SHARED by 6 methods, so it must never be DETOURED -- but a
# shared body is still correct code for the receiver passed to it, and the
# offset it names is confirmed by the metadata anyway.)
const OffCamMgrFov = 0xF8'i32

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

  RvaCameraGetMain = 0x5260400
    ## UnityEngine.Camera::get_main() -> Camera. rid=517, arity 0, STATIC,
    ## section `il2cpp`, sharedness=UNIQUE (owners=1), NOT the empty-body stub.
    ##
    ## This is the SAME acquisition the ESP overlay uses every frame in a live
    ## raid (host/Aowlspt.Host.Il2Cpp/debugui.nim resolves
    ## "UnityEngine.Camera::get_main" through its C target table and calls it as
    ## `cDuCallPV`). Added because CameraManager.Instance.<Camera>@0x70 reads
    ## NULL in-raid on this build -- MEASURED live: "CameraManager is live but
    ## its Camera backing field @0x70 is null". get_main returns the tagged main
    ## camera directly and does not depend on that offset, so the base-FOV
    ## capture and get_fieldOfView read from a camera that is actually there.
    ##
    ## Bytes below via `il2cpp_resolve.py ... bytes 0x5260400 16`; the prologue
    ## is `sub rsp,0x28; mov rax,[rip+0x1E727D5]; test rax,rax; jne ...` -- the
    ## cached-main-camera fast path, a real body, not a thunk.
  ProCameraGetMain = "48 83 EC 28 48 8B 05 D5 27 E7 01 48 85 C0 75 18"

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

  # ---------------------------------------------------------------------
  # The four members that used to be reached BY NAME, and are not any more.
  # ---------------------------------------------------------------------
  #
  # `bindOnObject` reached `get_MainPlayer`, `get_ProceduralWeaponAnimation`,
  # `get_IsAiming` and `get_fieldOfView` through
  # `il2cpp_object_get_class` -> `il2cpp_class_get_name`. The second of those
  # is TOKEN-GATED: on gate mismatch it answers a uniform random NON-ZERO
  # uint64, `readCString`'s nil check passes, and the first dereference kills
  # the process. MEASURED (fact #198): Application Error 1000 at 10:30:54,
  # faulting module fov.dll, 0xC0000005 at fault offset 0x47B85, which `nm`
  # places at +0x31 inside `readCString`. That by-name path had never
  # executed before aadbc0b removed the world gate that was returning on
  # frame 1 forever.
  #
  # Three of the four are not calls at all -- they are FIELD READS, and a
  # field read cannot be gated. The fourth is a real Unity property with no
  # backing field, so it is a byte-verified static RVA.
  #
  # Everything below is the verbatim output of
  #   python tools/il2cpp_resolve.py <GameAssembly.dll> <metadec> fields <T>
  #   python tools/il2cpp_resolve.py <GameAssembly.dll> <metadec> type <idx>
  #   python tools/il2cpp_symtab.py  find-method <GameAssembly.dll> <metadec> <m>
  # against the installed D:/Games/Tarkov/GameAssembly.dll, after
  # `verify-fields` printed the System.String self-check
  # (_stringLength@0x10, _firstChar@0x14) and PASSED. Nothing is guessed and
  # nothing is remembered.

  OffGameWorldMainPlayer = 0x230
    ## `EFT.GameWorld.MainPlayer`, a PUBLIC FIELD of declared type `Player`
    ## (attrs 0x0006). There is no `get_MainPlayer` on this build at all --
    ## the property the old code asked for does not exist, so `bindOnObject`
    ## was walking the WHOLE base chain to the root and taking a class name
    ## at every hop before it could say so.
    ##
    ## The subclass question that motivated `bindOnObject` does not arise for
    ## a field: IL2CPP lays base-class fields first, so a base offset is
    ## valid on every subclass. VERIFIED rather than assumed -- `fields`
    ## reports MainPlayer at 0x230 declared by EFT.GameWorld on
    ## ClientLocalGameWorld, ClientNetworkGameWorld, EFT.ClientGameWorld and
    ## HideoutGameWorld alike, which is every GameWorld the host can hand us.

  OffPlayerPwa = 0x3c0
    ## `EFT.Player.<ProceduralWeaponAnimation>k__BackingField`. Same
    ## subclass check: `fields EFT.LocalPlayer` reports it at 0x3c0, declared
    ## by EFT.Player.

  OffPwaIsAiming = 0x16d
    ## `EFT.Animations.ProceduralWeaponAnimation._isAiming`, a private bool.
    ##
    ## CROSS-CHECKED against the getter's own machine code rather than
    ## trusted from the field table alone:
    ## `ProceduralWeaponAnimation::get_IsAiming` is at 0xEBB130 and begins
    ## `48 83 EC 28 80 B9 6D 01 00 00 00` -- `sub rsp,0x28;
    ## cmp byte [rcx+0x16D],0`. The getter IS this field read. Two
    ## independent instruments agreeing on 0x16D is what makes reading it
    ## directly safe rather than convenient.

  RvaCurrentScope = 0xebb990
    ## `EFT.Animations.ProceduralWeaponAnimation::get_CurrentScope()`
    ## -> SightNBone. rid unique, arity 0, INSTANCE, section `il2cpp`,
    ## owners=1 per `il2cpp_symtab.py find-method` -- NOT a shared RVA and
    ## not the universal empty-body stub at 0x628110.
    ##
    ## This one has no backing field (there is no
    ## `<CurrentScope>k__BackingField` in the type's field table), so it is a
    ## real computed property and has to be a call.
  ProCurrentScope = "48 89 5C 24 08 57 48 83 EC 20 80 3D 43 F5 1F 06"

  RvaIsOptic = 0xed4c30
    ## `SightNBone::get_IsOptic()` -> bool. arity 0, INSTANCE, `il2cpp`,
    ## owners=1.
    ##
    ## The old comment here claimed "CurrentScope's declared type is not the
    ## type of the object it returns", and used that to justify binding
    ## against the object. Metadata says otherwise: `get_CurrentScope`
    ## RETURNS `SightNBone` and `get_IsOptic` is declared BY `SightNBone`, so
    ## the declared type and the owner agree and there is nothing to
    ## discover. Note the trap the name alone would have walked into --
    ## `find-method get_IsOptic` also reports
    ## `GPUInstancer.GPUInstancerCameraData::get_IsOptic` at 0xBBA010 with
    ## FIFTEEN owners.
  ProIsOptic = "48 89 5C 24 08 57 48 83 EC 20 80 3D EA 62 1E 06"

  RvaCamFieldOfView = 0x525dce0
    ## `UnityEngine.Camera::get_fieldOfView()` -> float. arity 0, INSTANCE,
    ## `il2cpp`, owners=1, in UnityEngine.CoreModule.dll's methodPointers
    ## table (which is why a per-module resolver matters here).
    ##
    ## The only one of the four that stays a call: `UnityEngine.Camera`
    ## declares no il2cpp field for it -- the value lives native-side -- so
    ## there is no offset to read. The float comes back in XMM0.
    ##
    ## Again the by-name hazard the RVA sidesteps:
    ## `ProceduralWeaponAnimation::get_FieldOfView` and
    ## `EFT.Hideout.HideoutCamera::get_FieldOfView` (2 owners) both answer to
    ## a case-insensitive search for this name.
  ProCamFieldOfView = "40 53 48 83 EC 20 48 8B 05 63 4D E7 01 48 8B D9"

  RvaCamSetFieldOfView = 0x525dd30
    ## `UnityEngine.Camera::set_fieldOfView(float)`. rid=427, arity 1,
    ## INSTANCE, image UnityEngine.CoreModule.dll, section `il2cpp`,
    ## sharedness=UNIQUE (owners=1), NOT the 0x628110 empty-body stub.
    ##
    ## WHY THIS EXISTS AT ALL, and it is the fix for "the FOV stuff doesn't
    ## appear to do anything". MEASURED, by disassembling
    ## `CameraManager::SetFov(float,float,bool)` @0x1268D20 off the installed
    ## GameAssembly.dll:
    ##
    ##     181268D9D  mov rdi, [rbx+0x70]      ; CameraManager.<Camera>
    ##     181268E06  test rdi, rdi
    ##     181268E09  je   0x181268F6C         ; <- THE EPILOGUE
    ##     181268E24  cmp qword [rdi+0x10], 0  ; Unity m_CachedPtr
    ##     181268E29  je   0x181268F6C         ; <- THE EPILOGUE
    ##
    ## So `SetFov` reads the SAME `<Camera>k__BackingField` @0x70 that was
    ## MEASURED NULL in-raid on this build (fact #260), and when it is null it
    ## RETURNS WITHOUT DOING ANYTHING. Everything after those two branches --
    ## the `ApplyDovFovOnCamera` store @0xa0, the coroutine object that carries
    ## `x` @0x20 and `time` @0x30, `StartCoroutine`, `_fovCoroutine` @0x100 --
    ## is unreachable.
    ##
    ## The earlier fix swapped the camera we READ from `@0x70` to
    ## `Camera::get_main`. It did not change where the write GOES, so the write
    ## still went to a method that returns immediately. The call succeeded,
    ## `gFovWrites` counted up, and the rendered FOV never moved: a check that
    ## cannot fail (CLAUDE.md 9b). Writing the camera we actually hold is the
    ## only route that does not depend on the null offset.
    ##
    ## Bytes below from `il2cpp_resolve.py ... bytes 0x525dd30 16` against
    ## D:/Games/Tarkov/GameAssembly.dll.
  ProCamSetFieldOfView = "40 53 48 83 EC 30 48 8B 05 1B 4D E7 01 48 8B D9"

# ---------------------------------------------------------------------------
# The three effects that used to be reached BY NAME (fatal on the client), now
# expressed as host patch-by-RVA specs.
# ---------------------------------------------------------------------------
#
# Each is an `RvaPatchTarget` (the mod ABI's patch-by-RVA description) handed to
# `hookRva`/`hookReturnRva`, which build the host spec string and pass it to
# `patchTyped`. The
# host resolves the ADDRESS from the RVA, so no `il2cpp_*` name lookup happens
# and the token-gated export ABI (fact #217) is never touched; it then
# byte-verifies the declared prologue against the STARTUP SNAPSHOT (not live
# memory, so another feature's trampoline cannot make a correct RVA self-reject),
# checks the target is committed executable memory inside the il2cpp PE section,
# and refuses out loud on any miss. The `<shape>` (instance/static, one letter
# per DECLARED argument, `>` + return letter) is what a bare RVA cannot carry and
# is REQUIRED; ours are DERIVED offline, not guessed:
#
#   il2cpp_resolve.py <GA> <metadec> type 6835  -> float get_AimingSensitivity()      i>f
#   il2cpp_resolve.py <GA> <metadec> type 11841 -> float get_GetCurrentSensitivity()  i>f
#   il2cpp_resolve.py <GA> <metadec> type 7013  -> void  CalculateScaleValueByFov(float) if>x
#
# `expect: rvaExpectUnique` is no longer a claim in a comment. The host looks
# each name up in the offline index at the arity the shape declares and refuses
# unless that entry maps to THIS RVA with exactly one owner -- and refuses again
# if anything has already detoured the function, because the second detour on a
# function overwrites the first's trampoline and kills it silently.
# The prologue bytes are the verbatim `il2cpp_resolve.py bytes <RVA> 16` output
# for each address, and the host compares them against its STARTUP SNAPSHOT
# before it writes anything.
#
# Procs rather than `const`/`let` globals, and that is not style: in a nimony
# `--app:lib` build a global initialised by anything the compiler cannot fold is
# left ZEROED, so a target built by a call at module scope would arrive at the
# host as an empty name and an RVA of 0. `gameType` in the mod API carries the
# same warning for the same reason.

proc tgtAimSens(): RvaPatchTarget =
  ## `float get_AimingSensitivity()` -- instance, no arguments, returns float.
  ##
  ## THE NAME IS `FirearmController::...`, NOT `EFT.Player.FirearmController::...`,
  ## and the difference is measured rather than stylistic: on this build the
  ## nested type carries no namespace, so the longer spelling is not a key in
  ## the offline name index at all (`il2cpp_nameindex.py lookup ... 0` ->
  ## NOT FOUND, while the short one -> 0x7773F0, not shared). The mod carried
  ## the long one for weeks with no consequence, because in a hand-built spec
  ## string the name is only ever printed; it is looked up now, to cross-check
  ## this RVA and to read the share count, so a wrong name is a refusal.
  RvaPatchTarget(name: "FirearmController::get_AimingSensitivity",
            rva: 0x7773F0'u32,
            shape: "i>f",
            prologue: @[
                        0x40'u8, 0x53'u8, 0x48'u8, 0x83'u8, 0xEC'u8, 0x20'u8,
                        0x48'u8, 0x8B'u8, 0x11'u8, 0x48'u8, 0x8B'u8, 0xD9'u8,
                        0x48'u8, 0x8B'u8, 0x82'u8, 0xC8'u8],
            expect: rvaExpectUnique)

proc tgtScopeSens(): RvaPatchTarget =
  ## `float get_GetCurrentSensitivity()` -- instance, no arguments, returns
  ## float (rid 72574, `il2cpp_resolve.py type 11841`). Index key confirmed
  ## present and UNIQUE at arity 0.
  RvaPatchTarget(name: "EFT.InventoryLogic.SightComponent::get_GetCurrentSensitivity",
            rva: 0x104A140'u32,
            shape: "i>f",
            prologue: @[
                        0x40'u8, 0x53'u8, 0x48'u8, 0x83'u8, 0xEC'u8, 0x20'u8,
                        0x80'u8, 0x3D'u8, 0x48'u8, 0x17'u8, 0x07'u8, 0x06'u8,
                        0x00'u8, 0x48'u8, 0x8B'u8, 0xD9'u8],
            expect: rvaExpectUnique)

proc tgtScaleValue(): RvaPatchTarget =
  ## `void CalculateScaleValueByFov(float)` -- instance, ONE float argument,
  ## returns VOID (rid 42126, `il2cpp_resolve.py type 7013`). The void return
  ## is why this effect is a prefix that SUPPRESSES rather than one that
  ## returns a number: the old code returned a value a void method never
  ## yields. Index key confirmed present and UNIQUE at arity 1.
  RvaPatchTarget(name: "EFT.Player::CalculateScaleValueByFov",
            rva: 0x6FC250'u32,
            shape: "if>x",
            prologue: @[
                        0xF3'u8, 0x0F'u8, 0x5C'u8, 0x0D'u8, 0x40'u8, 0xA6'u8,
                        0xEB'u8, 0x05'u8, 0xF3'u8, 0x0F'u8, 0x10'u8, 0x05'u8,
                        0xA0'u8, 0x9D'u8, 0xEB'u8, 0x05'u8],
            expect: rvaExpectUnique)

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
# THE OBJECT-BINDING PATH IS GONE. Deleted, not disabled.
# ---------------------------------------------------------------------------
#
# What used to be here: `ObjBind`, `noObjBind`, `statedKindsDisagree` and
# `ensureCall` -- a cache that bound a member against the class a LIVE object
# reports, walking its base chain, keyed on that class so the walk happened
# once per class rather than per frame.
#
# The reasoning was sound and the mechanism was fatal. `bindOnObject` reaches
# `il2cpp_object_get_class` (which is `mov rax,[rcx]; ret` and validates
# nothing) and then `il2cpp_class_get_name`, which is one of the 38
# TOKEN-GATED exports: called without the trailing 32-byte token it answers a
# uniform random NON-ZERO uint64 instead of NULL. `readCString` nil-checked
# that, passed, and dereferenced it. MEASURED: 0xC0000005, faulting module
# fov.dll, fault offset 0x47B85 = `readCString` +0x31 (fact #198).
#
# `ensureCall`'s own `if c == nil: return false` was a CHECK THAT COULD NOT
# FIRE, which is the shape CLAUDE.md 9b names. It is not fixed here; it is
# removed, because the thing it was guarding should not run in this client at
# all.
#
# The replacement is not a safer lookup. It is NO lookup: three field reads at
# offsets derived offline from `Il2CppMetadataRegistration.fieldOffsets`, and
# three calls at static RVAs whose 16 prologue bytes are compared against the
# installed DLL before anything is called. A field read cannot be gated, and a
# direct RVA call bypasses the export ABI entirely.
#
# The subclass problem `bindOnObject` existed to solve does not survive the
# change. For the two reference hops it never applied: IL2CPP lays base-class
# fields first, so `EFT.GameWorld.MainPlayer@0x230` and
# `EFT.Player.<ProceduralWeaponAnimation>k__BackingField@0x3c0` read correctly
# from any subclass -- verified against ClientLocalGameWorld,
# ClientNetworkGameWorld, EFT.ClientGameWorld, HideoutGameWorld and
# EFT.LocalPlayer. For the three calls, none of the three methods is virtual
# on a type with an overriding subclass, and each was checked to have
# owners=1 (not a shared RVA, not the universal stub).
#
# What is LOST, and is worth stating rather than hiding: the stated-kinds
# cross-check. `statedKindsDisagree` compared this mod's asserted register
# classes against the runtime's own `MethodInfo`, so a future build that
# changed `get_fieldOfView` to return a `System.Double` would have been
# caught. That check ran through `il2cpp_method_get_return_type`, i.e.
# through the same export surface, so it cannot be kept. The equivalent
# guarantee now lives OFFLINE and is stronger: the prologue byte-compare in
# `bindAtRva` fails closed the moment BSG recompiles the body, and the
# signatures above came from metadata rather than from memory.


proc noKinds(): seq[FastKind] =
  ## An empty argument list for `bindAtRva`. A bare `[]` literal has no type
  ## for nimony to infer at that call site, so the empty seq is named once.
  result = @[]

# The FOV chain, in full. EVERY entry is a byte-verified static RVA; there is
# no by-name binding left in this mod's frame path at all. Declared bare and
# assigned from a proc: a nimony `--app:lib` global initialised by a *call* is
# silently left zeroed, and a zeroed `Binding` has `ok = false`, so it fails
# safe but never becomes true. See fast.nim's rule 1.
var bCamInstance: Binding      ## CameraManager::get_Instance, static RVA
var bCamMain: Binding          ## UnityEngine.Camera::get_main, static RVA (ESP's proven path)
var bSetFov: Binding           ## CameraManager::SetFov(f,f,b), static RVA
var bGetKey: Binding           ## Input::GetKey(KeyCode), static RVA
var bGetKeyDown: Binding       ## Input::GetKeyDown(KeyCode), static RVA
var bCamFov: Binding           ## UnityEngine.Camera::get_fieldOfView, static RVA
var bCamSetFov: Binding        ## UnityEngine.Camera::set_fieldOfView, static RVA
  ## THE WRITE THAT ACTUALLY LANDS. `bSetFov` (CameraManager::SetFov) reads
  ## `<Camera>@0x70` and returns immediately when it is null, which it
  ## MEASURED is on this build -- see `RvaCamSetFieldOfView`.
var bCurrentScope: Binding     ## ProceduralWeaponAnimation::get_CurrentScope, static RVA
var bIsOptic: Binding          ## SightNBone::get_IsOptic, static RVA
  ## `bWorld` is GONE. There is no `EFT.GameWorld::get_Instance` on this
  ## build (409 members, zero matches), the by-name attempt to find one was
  ## the statement that killed the client, and the world now arrives from
  ## the host export `aowl_host_gameworld` as an already-live object.
  ##
  ## `obMainPlayer`, `obPwa`, `obIsAiming` and `obCamFov` are gone with it.
  ## The first three are FIELD READS now (OffGameWorldMainPlayer,
  ## OffPlayerPwa, OffPwaIsAiming) and the fourth is `bCamFov` above.

var gSetFovArgc = 0
var gOpticChainState = "not attempted"
var gBaseFov = 0.0
var gLastFovTicks = 0'i64
var gFovNs = 0'i64
var gFovSamples = 0
var gFovBoundSaid = false

var gFovDisabled = false
  ## Set once, never cleared this run. When true the FOV write is dead for the
  ## rest of the session -- rule 6, self-disable after N faults. Declared here,
  ## ahead of `applyFov`, because `applyFov` checks it; the counter that trips it
  ## (`gFovTickInflight`) and the gate proc live next to the driver that owns
  ## them.

var gZoomKeyCode = -1          ## resolved from cfgZoomToggleKey; -1 = refused
var gZoomKeyState = "not attempted"
var gZoomLatch = false         ## the toggle latch, when holdToZoom is off
var gZoomOn = false            ## what the last poll decided
var gZoomFrames = 0'i64        ## FOV writes taken with the zoom key asserted
var gLastAiming = false
var gLastKeyTicks = 0'i64

# ---------------------------------------------------------------------------
# The ADS transition smoother
# ---------------------------------------------------------------------------
#
# THE FORMULA, stated once here and printed into the log at arm time so it can
# be checked against what the player sees:
#
#   mult   = 1.0                                      hip, no zoom key
#          = opticFovMulti | nonOpticFovMulti         aiming
#          x opticToggleZoomMulti | nonOpticToggleZoomMulti   aiming + zoom key
#          x unaimedToggleZoomMulti                   not aiming + zoom key
#   target = BASE_FOV * mult
#   fov(t) = from + (target - from) * ease(t / duration)
#
# Every multiplier composes onto BASE_FOV -- the field of view captured once
# from a camera this mod has never written to -- and NEVER onto the previous
# frame's output. A per-frame multiply against the live value compounds
# geometrically and is the classic drift bug; the smoother interpolates a
# POSITION between two absolute endpoints, so it cannot drift either.
var gCurFov = 0.0        ## what we last asked the camera to render
var gSmFrom = 0.0        ## the FOV this transition started from
var gSmTo = 0.0          ## the FOV this transition is heading to
var gSmT = 0.0           ## seconds elapsed in this transition
var gSmDur = 0.0         ## seconds this transition is allowed to take
var gSmToAds = false     ## direction: true = into ADS/zoom
var gSmSettled = true    ## the transition has finished
var gSmVerified = true   ## ...and its finished state has been read back
var gSmElapsed = 0.0     ## how long the last completed transition really took
var gSmVerdict = "INCONCLUSIVE -- no ADS transition has completed yet"
var gSmPasses = 0
var gSmFails = 0
var gLastRest = false    ## the previous write left us at rest on the base FOV

# ---- Observing the GAME's own ADS ramp (cfgAdsDeferToGame).
#
# While `gAdsObserving` this mod writes NOTHING. It samples the field of view
# the game itself is rendering and waits for that ramp to finish.
#
# The settle test is deliberately not "two samples the same". CLAUDE.md 9b: a
# tick with no movement is INDISTINGUISHABLE from a tick before the game's ramp
# has started, and a settle loop that accepts the second one declares victory
# immediately and learns the HIP FOV as the ADS FOV -- which would be the same
# class of bug, dressed differently. So stillness is only accepted AFTER motion
# has actually been observed (`gAdsMoved`). If no motion is ever seen within
# `cfgAdsObserveCap` seconds the answer is INCONCLUSIVE, said out loud, and the
# old base*mult endpoint is used -- never a silent decline.
var gAdsObserving = false
var gAdsObsT = 0.0       ## seconds spent observing this ADS-in
var gAdsPrev = 0.0       ## the previous sample of the game's own FOV
var gAdsMoved = false    ## the game's FOV has been SEEN to move at least once
var gAdsStill = 0        ## consecutive samples within cfgAdsSettleEps
var gAdsBase = 0.0       ## the game's SETTLED ADS FOV; 0 = not learned yet
var gAdsStart = 0.0      ## the FOV when this ADS-in began (for the log line)
var gAdsVerdict = "INCONCLUSIVE -- no ADS-in has been observed yet"
var gAdsLearns = 0
var gAdsGiveUps = 0
var gAdsPendReport = false  ## an ADS-in endpoint was written last tick and its
                            ## survival has not been read back yet
var gAdsPendTarget = 0.0    ## ...that endpoint
var gAdsPendGameFov = 0.0   ## the game's OWN settled ADS fov, READ FROM THE
                            ## GAME -- never our own last write
var gAdsPendPath = ""       ## which branch produced it, named in the log line
var gAdsIns = 0             ## how many aim-ins have been seen AT ALL
var gAimWasAiming = false
var gAdsConsecFails = 0     ## consecutive ADS-ins whose endpoint did not survive
var gAdsNoFight = false     ## we have conceded the field of view while aiming
var gAdsProbeN = 0          ## samples emitted by the read-only writer probe
var gHoldProbeN = 0         ## samples emitted by the one-shot hold probe
var gAdsFieldState = "no CameraManager._fov write has been attempted yet"
var gAdsFieldWrites = 0
var gAdsHoldWrites = 0      ## per-frame re-asserts of the ADS endpoint (the hold)
var gAdsHoldSaid = false
var gAdsFieldRefusals = 0

# ---- THE READ-ONLY WRITER PROBE.
#
# Once `gAdsNoFight` is set this mod writes NOTHING while aiming, which makes
# the next aim-in a clean experiment: any movement in Camera.fieldOfView during
# it is somebody else's, and its per-frame cadence says whether that somebody
# assigns once or drives continuously. HARD-CAPPED at 40 lines for the whole
# process lifetime, reusing the already-bound, already-prologue-verified
# Camera::get_fieldOfView -- it adds no new RVA row, which matters while the
# 128-row startup-snapshot table is known to be near its bound.
const AdsProbeMax = 40
var gBaseCam: Il2CppPtr = nil
  ## WHICH camera `gBaseFov` was captured from. The menu camera and the raid
  ## camera are different objects, and `Camera::get_main` answers in both. A
  ## base captured at the main menu and then multiplied against a raid camera
  ## is exactly the "it is wrong / not calibrated" report: the number is
  ## plausible, applied, and derived from the wrong screen. Identity change
  ## forces a re-capture rather than being invisible.

proc adsInDuration(): float =
  ## Seconds, hip -> ADS. Never zero: a zero duration is a step change, which
  ## is the bug this is fixing, and it would also divide by zero below.
  if cfgUseAimSpeedsForFov:
    let s = (if cfgRifleAimSpeedZ > 0.01: cfgRifleAimSpeedZ else: 0.01)
    result = 1.0 / s
  else:
    result = cfgAdsSmoothTime
  if result < 0.01: result = 0.01
  if result > 2.0: result = 2.0

proc adsOutDuration(): float =
  if cfgUseAimSpeedsForFov:
    let s = (if cfgUnAimSpeedZ > 0.01: cfgUnAimSpeedZ else: 0.01)
    result = 1.0 / s
  else:
    result = cfgUnAdsSmoothTime
  if result < 0.01: result = 0.01
  if result > 2.0: result = 2.0

proc easeAt(p: float): float =
  ## `p` is progress in 0..1. Smoothstep by default; linear when asked. No
  ## allocation, no libm, no branchless cleverness -- this runs every frame.
  if p <= 0.0: return 0.0
  if p >= 1.0: return 1.0
  if cfgAdsSmoothLinear: return p
  result = p * p * (3.0 - 2.0 * p)

proc fabsf(x: float): float =
  if x < 0.0: -x else: x

proc resetSmoother(baseline: float) =
  ## Called when the camera identity changes, i.e. when everything the
  ## smoother believed was measured against an object that is gone.
  gCurFov = baseline
  gSmFrom = baseline
  gSmTo = baseline
  gSmT = 0.0
  gSmDur = 0.0
  gSmSettled = true
  # Anything learned about the GAME's ADS FOV was learned from the camera that
  # is gone, so it is not carried across.
  gAdsObserving = false
  gAdsBase = 0.0
  gAdsMoved = false
  gAdsStill = 0
  gAdsObsT = 0.0
  gLastRest = false

# --- the CameraManager acquisition, reported three ways, never two.
#
# The receiver is obtained from the STATIC, byte-verified
# `CameraManager::get_Instance` @0x1263bd0 and depends on NOTHING else -- in
# particular not on the host export `aowl_host_gameworld`, which is the thing
# that was actually missing (`gwState()` 0) and which silently vetoed this
# whole path before the camera was ever asked for. The world is still used,
# when present, for the AIMING multiplier only; without it the aim-dependent
# multipliers degrade to 1.0 and the toggle-zoom multiplier still applies.
#
# Three outcomes, never two (CLAUDE.md 9b):
#   ccUnknown  nothing has been tried yet
#   ccAbsent   get_Instance returned NULL. Benign in a menu -- and if the
#              world export cannot tell us whether we are in a raid, this is
#              INCONCLUSIVE and says so rather than reading as patience.
#   ccBroken   we have evidence we are in a game (a live GameWorld, or the
#              player is HOLDING the zoom key) and STILL have no usable
#              camera. That is a bug, and it is logged loudly, once, and then
#              at a decaying rate -- not swallowed.
#   ccLive     camera in hand.
type CamAcq = enum ccUnknown, ccAbsent, ccBroken, ccLive
var gCamAcq = ccUnknown
var gCamNullFrames = 0'i64     ## consecutive frames with no usable camera
var gCamBrokenFrames = 0'i64   ## ... of which had evidence of being in-game
var gCamBrokenSaid = 0'i64     ## how many times we have shouted about it
var gCamWhy = "not attempted"  ## the LAST concrete reason there was no camera
var gCamLiveSaid = false
var gLastMult = -1.0
var gAimSourceState = "not attempted"
var gWriteRoute = "not attempted"
  ## Which of the two writes actually ran: `Camera::set_fieldOfView` (lands)
  ## or `CameraManager::SetFov` (MEASURED inert while <Camera>@0x70 is null).
var gWriteVerdict = "INCONCLUSIVE -- no write has been read back yet"
  ## THE FINISHED-STATE CHECK (CLAUDE.md 9b), not a self-comparison. After a
  ## write, `get_fieldOfView` is read back off the SAME camera and compared to
  ## the target. It can genuinely fail: that is exactly what the shipped
  ## `SetFov` path does, every frame, while counting itself a success.
var gWriteTook = 0
var gWriteMissed = 0
var gLastTarget = 0.0
var gHeldVerdict = "INCONCLUSIVE -- no second sample yet"

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

proc setFieldOfViewKinds(): seq[FastKind] =
  ## `void set_fieldOfView(float value)` -- one float, XMM0 after `this`.
  ## From the offline signature (`il2cpp_resolve.py type 22882`, rid=427),
  ## not from `classifyType`.
  result = @[]
  result.add fkF32

proc bindFovStatics(): bool =
  ## EVERY member the frame path calls, bound HERE, once, at a byte-verified
  ## static RVA. Nothing is bound per frame and nothing is bound by name.
  ##
  ## This proc used to reset six `ObjBind` caches that the frame path would
  ## then fill in by asking a live object for its class. That is the path
  ## that killed the client; see the comment block above the FOV chain.

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

  # Camera::get_main -- the SAME acquisition the ESP overlay uses live every
  # frame. NON-FATAL: if it refuses, applyFov falls back to the
  # CameraManager.Instance.<Camera>@0x70 field read. It is preferred there
  # because @0x70 was MEASURED null in-raid on this build while get_main
  # returns the tagged main camera the ESP successfully reads.
  bc "S1b about to prologue-verify Camera::get_main"
  bCamMain = bindAtRva("UnityEngine.Camera::get_main", RvaCameraGetMain,
                       ProCameraGetMain, noKinds(), fkPtr, true)
  if bCamMain.ok:
    info "FOV: " & bCamMain.why
  else:
    warn "FOV: Camera::get_main refused (" & bCamMain.why & ") -- will fall " &
         "back to CameraManager.Instance.Camera@0x70 for the camera"

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

  # The three members that used to be bound against a live object, now bound
  # exactly like the four above. NON-FATAL, individually, and in descending
  # order of how much the effect loses without them:
  #
  #   * `get_fieldOfView` gone  -> no base FOV can be captured, so the write
  #     is refused outright. Fatal to the effect, and said so below.
  #   * `get_CurrentScope` / `get_IsOptic` gone -> every aim is treated as
  #     UNMAGNIFIED. That is a REDUCED effect, not a wrong one, and it is
  #     reported on its own line rather than folded into success.
  bc "S3b about to prologue-verify Camera::get_fieldOfView"
  bCamFov = bindAtRva("UnityEngine.Camera::get_fieldOfView", RvaCamFieldOfView,
                      ProCamFieldOfView, noKinds(), fkF32, false)
  if not bCamFov.ok:
    gFovState = "refused: " & bCamFov.why
    warn "FOV: " & gFovState
    return false
  info "FOV: " & bCamFov.why

  # THE WRITE ITSELF. Non-fatal on its own -- if it refuses we fall back to
  # CameraManager::SetFov, which is what shipped, and which is MEASURED inert
  # whenever CameraManager.<Camera>@0x70 is null. That fallback is therefore
  # reported as a DEGRADED path, never as success.
  bc "S3b2 about to prologue-verify Camera::set_fieldOfView"
  bCamSetFov = bindAtRva("UnityEngine.Camera::set_fieldOfView",
                         RvaCamSetFieldOfView, ProCamSetFieldOfView,
                         setFieldOfViewKinds(), fkVoid, false)
  if bCamSetFov.ok:
    info "FOV: " & bCamSetFov.why
  else:
    warn "FOV: Camera::set_fieldOfView refused (" & bCamSetFov.why &
         ") -- falling back to CameraManager::SetFov @0x" & hexs(RvaSetFov3) &
         ", which is MEASURED to return without writing anything whenever " &
         "CameraManager.<Camera>@0x70 is null (it is, on this build). " &
         "Expect the FOV to visibly do NOTHING on that path."

  bc "S3c about to prologue-verify get_CurrentScope / get_IsOptic"
  bCurrentScope = bindAtRva(
    "ProceduralWeaponAnimation::get_CurrentScope", RvaCurrentScope,
    ProCurrentScope, noKinds(), fkPtr, false)
  bIsOptic = bindAtRva("SightNBone::get_IsOptic", RvaIsOptic, ProIsOptic,
                       noKinds(), fkBool, false)
  if bCurrentScope.ok and bIsOptic.ok:
    gOpticChainState = "armed (get_CurrentScope @0x" & hexs(RvaCurrentScope) &
                       " -> get_IsOptic @0x" & hexs(RvaIsOptic) &
                       ", both prologue-verified 16/16)"
    info "FOV: " & bCurrentScope.why
    info "FOV: " & bIsOptic.why
  else:
    gOpticChainState = "REFUSED -- every aim will be treated as unmagnified: " &
                       (if bCurrentScope.ok: bIsOptic.why else: bCurrentScope.why)
    warn "FOV: optic detection " & gOpticChainState

  bc "S3 all seven RVAs verified; bindFovStatics returning true"
  gFovState = "arming: SetFov verified at 0x" & hexs(RvaSetFov3) &
              " with 3 argument(s); the CameraManager is acquired per frame " &
              "from the verified static get_Instance"
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
  if not bCamFov.ok:
    return
  a.reset()
  result = callFloat(bCamFov, cam, a)

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

proc inGameEvidence(): bool =
  ## Positive evidence that we are IN A GAME, from two INDEPENDENT sources, so
  ## that a missing `aowl_host_gameworld` export cannot by itself make a real
  ## failure look like a menu:
  ##   * the host has a live GameWorld cached (gwState 3), or
  ##   * the player is physically asserting the zoom key right now.
  ## Neither can fire in a main menu with the key untouched, and the second
  ## needs no host export at all.
  result = gwState() == 3 or gZoomOn

proc noCamera(why: string) =
  ## The per-frame "still no camera" reporter. Distinguishes NO RAID YET from
  ## IN A RAID AND STILL BROKEN, and shouts about the second.
  gCamWhy = why
  gCamNullFrames = gCamNullFrames + 1'i64
  if not inGameEvidence():
    gCamAcq = ccAbsent
    gCamBrokenFrames = 0'i64
    gFovState = "no CameraManager yet -- " & why & ". No evidence of being " &
                "in a game (" & gwStateText() & "), so this is INCONCLUSIVE, " &
                "not a pass."
    return
  gCamAcq = ccBroken
  gCamBrokenFrames = gCamBrokenFrames + 1'i64
  gFovState = "BROKEN: in a game (" & (if gwState() == 3: "GameWorld live"
              else: "zoom key held") & ") for " & $gCamBrokenFrames &
              " frames and STILL no usable camera -- " & why
  # Loud, then decaying: frame 1, 250, 2500, 25000 ... never silent, never a
  # per-frame log flood. Capped by the counter itself, not by a loop.
  if gCamBrokenFrames == 1'i64 or gCamBrokenFrames == 250'i64 or
     gCamBrokenFrames == 2_500'i64 or gCamBrokenFrames == 25_000'i64:
    gCamBrokenSaid = gCamBrokenSaid + 1'i64
    warn "FOV: " & gFovState & " -- this is a BUG in the mod's camera " &
         "acquisition, not patience. Camera::get_main (0x" &
         hexs(RvaCameraGetMain) & ", the ESP's proven path) and " &
         "CameraManager::get_Instance (0x" & hexs(RvaCamInstance) &
         ") are both byte-verified."

proc camIsLive() =
  gCamAcq = ccLive
  gCamNullFrames = 0'i64
  gCamBrokenFrames = 0'i64
  gCamWhy = ""
  if not gCamLiveSaid:
    gCamLiveSaid = true
    success "FOV: a live CameraManager and Camera are in hand, from the " &
            "static verified get_Instance -- no host export involved."

proc applyFov() =
  ## Upstream's `FovController.Update`, on the fast path.
  ##
  ## Runs inside a patched game method, so it is on the game thread and inside
  ## the game's own frame -- which is where a Unity write has to happen. Every
  ## pointer here is resolved fresh and dropped before the call returns: rule 4
  ## in docs/PERF.md, and the reason nothing in this file stores one.
  if gFovDisabled:
    # Self-disabled after a fault storm (rule 6). Checked here too so the
    # `hookFrameDriver` path (onWatched -> applyFov) also stops, not just the
    # everyMain driver that trips the switch.
    return
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
  # The REAL elapsed time since the last tick that got through this gate, in
  # seconds. The smoother must be driven by measured time and not by a frame
  # count: the gate above skips frames by design, so a per-tick constant would
  # make the transition take a different wall-clock time on every machine.
  # Clamped: a first tick, an alt-tab, or a loading screen produces a huge dt
  # that would jump the transition straight to its endpoint -- i.e. the step
  # change this is replacing.
  var dt = 0.0
  if gLastFovTicks != 0'i64:
    dt = float(nanosBetween(gLastFovTicks, now)) / 1_000_000_000.0
    if dt < 0.0: dt = 0.0
    if dt > 0.25: dt = 0.25
  gLastFovTicks = now
  let measuring = gFovSamples < CostSamples

  let firstPass = gFovWrites == 0'i64 and not gFovBoundSaid
  if firstPass: bc "A1 applyFov: past the rate gate"
  var a = noArgs()
  # The world, from the host's cache rather than from a type probe. `gwWorld`
  # returns nil for states 0, 1 and 2 alike -- and states 0 and 1 are
  # INCONCLUSIVE, not "no raid". A silent nil here must therefore never be
  # read as "not in a raid", which is why `onWorldReady` and `reportWatch`
  # both print `gwStateText()`: the three-way answer stays visible even
  # though this fast path can only branch two ways.
  # ---- 1. THE CAMERA FIRST. It needs no world and no player.
  #
  # This used to come LAST, behind `gwWorld()`. On the live run that motivated
  # this change the host exported no `aowl_host_gameworld` at all (gwState 0),
  # so the very first branch returned and `CameraManager::get_Instance` -- a
  # verified static RVA that would have answered immediately -- was never once
  # called. The arm-time string "waiting for a live CameraManager" was then the
  # only thing the player saw, and it was false: nothing was waiting on the
  # camera, everything was waiting on an export that does not exist.
  if firstPass: bc "B1 about to CALL CameraManager::get_Instance @0x1263bd0"
  let cm = callPtr(bCamInstance, nullPtr(), a)
  if firstPass: bc "B2 get_Instance returned without faulting"
  if cm == nil:
    if firstPass: bc "B2x get_Instance returned NULL -- returning"
    noCamera("CameraManager::get_Instance returned NULL")
    return
  # THE CAMERA TO READ FROM. cm (the CameraManager) is kept for SetFov below,
  # but the camera whose field of view we CAPTURE is acquired the way the ESP
  # overlay proves works every frame in a live raid: UnityEngine.Camera::get_main
  # (debugui.nim / DuCameraMain). CameraManager.Instance.<Camera>@0x70 was
  # MEASURED null in-raid on this build, so it is only a fallback now, not the
  # primary path -- and a null camera is treated as "not ready yet", the same
  # decaying INCONCLUSIVE report as before, never a claim that the offset works.
  var cam: Il2CppPtr = nil
  if bCamMain.ok:
    if firstPass: bc "B2m about to CALL Camera::get_main @0x5260400"
    a.reset()
    let m = callPtr(bCamMain, nullPtr(), a)
    if firstPass: bc "B2n get_main returned without faulting"
    if m != nil and fovReadable(m, 0x20):
      cam = m
      if firstPass: bc "B3 camera in hand (Camera::get_main)"
  if cam == nil:
    # Fallback: the old field read. `get_Camera` folds to 0x65ED10
    # (`mov rax,[rcx+0x70]; ret`), so reading the field is the same answer with
    # no shared-RVA exposure -- but on this build it reads null in a raid, which
    # is why get_main is tried first.
    if fovReadable(cm, OffCamManagerCamera + 8):
      let c2 = guardedField(cm, OffCamManagerCamera, "CameraManager.Camera")
      if c2 != nil:
        cam = c2
        if firstPass: bc "B3 camera in hand (CameraManager.Camera@0x70 fallback)"
  if cam == nil:
    if firstPass: bc "B3x no camera from get_main or @0x70 -- returning"
    noCamera("no usable camera: Camera::get_main returned null/unreadable and " &
             "CameraManager.Camera@0x70 is null (both tried)")
    return
  camIsLive()

  # ---- 2. THE PLAYER, OPTIONALLY. Only the AIM multipliers need it.
  #
  # A missing world degrades the effect (every frame is treated as unaimed) but
  # no longer vetoes it, so hold-to-zoom works in a raid even on a host with no
  # `aowl_host_gameworld` export. Which of the two happened is recorded in
  # `gAimSourceState` and printed in the roll-call, so a reduced effect can
  # never be mistaken for a working one.
  var pwa = cast[Il2CppPtr](0)
  if firstPass: bc "A2 about to ask the host export for the world"
  let w = gwWorld()
  if w == nil:
    gAimSourceState = "NO aiming input -- " & gwStateText() &
                      " Aim multipliers are inert; toggle zoom still applies."
    if firstPass: bc "A2x no world (host export state below 3) -- aim inert"
  elif not fovReadable(w, 16):
    gAimSourceState = "NO aiming input -- the world pointer was not readable"
    if firstPass: bc "A2y world pointer not readable -- aim inert"
  else:
    if firstPass: bc "A3 world in hand and readable"
    # TWO FIELD READS, NOT TWO BY-NAME CALLS. `guardedField` VirtualQueries
    # the object for `off+8` bytes, loads, and VirtualQueries the result
    # before anyone treats it as an object -- every hop checked, not just the
    # first. A field read cannot reach a token-gated export, so there is no
    # random-value failure mode on this path any more.
    if firstPass: bc "A4 about to READ GameWorld.MainPlayer @0x230"
    let player = guardedField(w, OffGameWorldMainPlayer, "GameWorld.MainPlayer")
    if player == nil:
      gAimSourceState = "NO aiming input -- GameWorld.MainPlayer @0x" &
                        hexs(OffGameWorldMainPlayer) &
                        " is null or unreadable (out of raid, or the world " &
                        "is not the one this offset was measured on)"
      if firstPass: bc "A5x MainPlayer field null -- aim inert"
    else:
      if firstPass: bc "A6 player in hand"
      pwa = guardedField(player, OffPlayerPwa, "Player.ProceduralWeaponAnimation")
      if pwa != nil:
        if firstPass: bc "A7 weapon animation in hand"
        gAimSourceState = "live (world -> MainPlayer@0x" &
                          hexs(OffGameWorldMainPlayer) &
                          " -> ProceduralWeaponAnimation@0x" &
                          hexs(OffPlayerPwa) & ", both field reads)"
      else:
        gAimSourceState = "NO aiming input -- " &
                          "Player.ProceduralWeaponAnimation @0x" &
                          hexs(OffPlayerPwa) & " is null or unreadable"
  a.reset()

  # Bound at arm time at a verified RVA, not per frame against the object.
  if not bCamFov.ok:
    gFovState = "refused: " & bCamFov.why
    return
  if firstPass: bc "B5 get_fieldOfView available at a verified RVA"

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
  #
  # ...FOR THIS CAMERA. `Camera::get_main` answers at the main menu too, and
  # the menu camera is a DIFFERENT object with a different field of view. A
  # base locked to it and then multiplied against the raid camera produces a
  # plausible, applied, wrong number -- which is what "it is not calibrated"
  # looks like from the outside. So the capture is keyed on camera IDENTITY,
  # and a new camera invalidates it. The new camera has never been written to
  # by us, so what is read back is the game's own value, not our output.
  if cam != gBaseCam:
    gBaseCam = cam
    gBaseFov = 0.0
    gLastTarget = 0.0
    gLastMult = -1.0
    gHeldVerdict = "INCONCLUSIVE -- the camera changed; nothing has been " &
                   "written to this one yet"
  if gBaseFov <= 0.0:
    a.reset()
    let seen = callFloat(bCamFov, cam, a)
    if seen <= 0.0:
      return
    gBaseFov = seen
    resetSmoother(seen)
    info "FOV: base field of view captured at " & $gBaseFov &
         " from a camera this mod has not written to. Every multiplier " &
         "composes onto THIS number, never onto the previous frame's output."

  var aiming = false
  if pwa != nil:
    # A BYTE FIELD READ, not a call. `ProceduralWeaponAnimation::get_IsAiming`
    # @0xEBB130 begins `cmp byte [rcx+0x16D],0` -- the getter IS this read, so
    # the two instruments agree and there is nothing left for a call to add.
    if fovReadable(pwa, OffPwaIsAiming + 1):
      aiming = fovByteAt(pwa, uint64(OffPwaIsAiming)) != 0'u8
    else:
      # Not a silent false: an unreadable object here means the pointer is
      # not what this offset was measured against, and acting on it would be
      # a blind write.
      gFovState = "refused: the ProceduralWeaponAnimation is not readable " &
                  "to +0x" & hexs(OffPwaIsAiming + 1) & ", so _isAiming " &
                  "cannot be read"
      return

  var optic = false
  if aiming:
    # Optic detection is optional. Without it every aim is treated as
    # unmagnified, which is a *reduced* effect rather than a wrong one, so a
    # refusal here does not veto the write -- but it is recorded and reported.
    if bCurrentScope.ok and bIsOptic.ok:
      a.reset()
      let scope = callPtr(bCurrentScope, pwa, a)
      # `get_CurrentScope` RETURNS SightNBone and `get_IsOptic` is declared BY
      # SightNBone -- checked in metadata rather than assumed, which is what
      # retires the old claim that the declared type was not the returned
      # one. The result is still VirtualQueried before it is used as a
      # receiver, because a call's return value is a pointer hop like any
      # other.
      if scope != nil and fovReadable(scope, 16):
        a.reset()
        optic = callBool(bIsOptic, scope, a)

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

  gLastMult = mult

  # ---- THE TRANSITION.
  #
  # `endpoint` is where the FOV belongs for the CURRENT state; `target` is
  # where it should be RIGHT NOW, part-way there. The old code wrote `endpoint`
  # directly, which is the step change the player reported.
  let wantAds = aiming or gZoomOn

  # ---- THE AIM-IN HEARTBEAT.
  #
  # The previous instrument printed NOTHING for a whole run, and there was no
  # way to tell "the feature is off" from "the player never aimed" -- which is
  # the same unfalsifiability that let the original bug survive. This fires on
  # the aiming edge itself, before any branch, gate or early return, so the
  # ABSENCE of ADS-in lines now means the player did not aim. It is rate-capped
  # to the first four and builds no string after that.
  if aiming != gAimWasAiming:
    gAimWasAiming = aiming
    if aiming:
      gAdsIns = gAdsIns + 1
      if gAdsIns <= 4:
        info "FOV: transition ADS-IN #" & $gAdsIns & " STARTED -- camera " &
             "fov now " & $gCurFov & ", hip base " & $gBaseFov & ", mult x" &
             $mult & ", strategy " &
             (if cfgAdsDeferToGame: "defer-to-game (this mod writes nothing " &
                                    "until the game's own ramp settles)"
              else: "our own ramp to base*mult (adsDeferToGame is OFF)")

  # ---- DID THE ADS-IN ENDPOINT SURVIVE A FRAME?  (CLAUDE.md 9b)
  #
  # Runs a full tick AFTER the endpoint was written, and BEFORE this tick writes
  # anything, so it reads what survived the frame rather than our own store.
  # `gAdsPendGameFov` is the game's own settled ADS field of view, read with
  # get_fieldOfView while this mod was writing nothing -- so the comparison is
  # against a value that came from the game, never against our arithmetic.
  # Unconditional: no `sampling` gate, no `gLastTarget` gate. One line per
  # aim-in, and it names the branch that produced it.
  if gAdsPendReport:
    gAdsPendReport = false
    if not bCamFov.ok:
      warn "FOV: transition ADS-IN #" & $gAdsIns & " INCONCLUSIVE -- " &
           "Camera::get_fieldOfView did not verify, so the rendered value " &
           "could not be read one frame on. Not a pass."
    else:
      a.reset()
      let live = callFloat(bCamFov, cam, a)
      let dEnd = fabsf(live - gAdsPendTarget)
      let dGame = fabsf(live - gAdsPendGameFov)
      # ONE FRAME IS NOT THE STATEMENT WHILE THE HOLD IS ON. MEASURED
      # 2026-09-06: with the per-frame hold, frame 1 read 57.0 (the game's
      # ramp still running) and frame 40 read the endpoint exactly -- so a
      # frame-1 FAIL here was contradicted by the HOLD VERDICT that followed.
      # With the hold on, this line reports the frame-1 reading as PENDING
      # and counts nothing; the hold's own verdict is the pass or fail.
      let holdPending = cfgAdsHoldEveryFrame and cfgAdsWriteFovField and
                        dEnd > 0.5
      let verdict =
        (if dEnd <= 0.5: "PASS"
         elif holdPending:
           "PENDING -- one frame after the settle write the camera is still " &
           "on the game's ramp; the per-frame hold is re-asserting the " &
           "endpoint and the HOLD VERDICT " & $AdsProbeMax & " frames on is " &
           "the statement, not this line."
         elif dGame <= 0.5:
           "FAIL -- the camera came back to the GAME's own ADS fov " &
           $gAdsPendGameFov & ". The game is still writing this field after " &
           "we do; our value does not survive the frame. THIS IS THE SNAP."
         else:
           "FAIL -- the camera is at neither our endpoint nor the game's " &
           "settled ADS fov; a third writer, or the sight changed mid-aim.")
      if dEnd <= 0.5:
        gSmPasses = gSmPasses + 1
        gAdsConsecFails = 0
      elif not holdPending:
        gSmFails = gSmFails + 1
        gAdsConsecFails = gAdsConsecFails + 1
      gSmVerdict = verdict
      info "FOV: transition ADS-IN #" & $gAdsIns & " " & verdict &
           " -- game's own ADS fov " & $gAdsPendGameFov & " (read while we " &
           "wrote nothing), hip base " & $gBaseFov & ", mult x" & $mult &
           ", our endpoint " & $gAdsPendTarget & ", camera ONE FRAME LATER " &
           $live & ", delta-to-endpoint " & $dEnd & ", delta-to-game " &
           $dGame & ", via " & gAdsPendPath
      # THE CONCESSION IS LIFTED while the input-side write is working.
      #
      # It was the right call while we believed we were losing a per-frame
      # tug-of-war; the 40-sample probe disproved that belief, so keeping it
      # would be acting on a measurement we know to be superseded. It now
      # engages ONLY if we never managed to write CameraManager._fov at all --
      # that is, only when there is no input-side route left and all that
      # remains is the output-side fight the player can see.
      if not gAdsNoFight and gAdsFieldWrites == 0 and
         gAdsConsecFails >= cfgAdsMaxFights:
        gAdsNoFight = true
        warn "FOV: CONCEDING the field of view while aiming. " &
             $gAdsConsecFails & " consecutive ADS-in endpoints failed to " &
             "survive a single frame, which means something writes " &
             "Camera.fieldOfView after we do, every frame -- a per-frame " &
             "tug-of-war this mod cannot win by writing the OUTPUT. What the " &
             "player sees while we keep trying is the oscillation reported as " &
             "'jumps in and out, then finally in again'. From now on this mod " &
             "writes NOTHING while aiming; the HIP field of view is " &
             "unaffected and still applied. The ADS multipliers " &
             "(opticFovMulti, nonOpticFovMulti) are INERT until the injection " &
             "point moves to the game's own input -- see the probe lines that " &
             "follow, which sample the field while we write nothing."

  # ---- WE HAVE CONCEDED: WRITE NOTHING WHILE AIMING.
  #
  # This is also the clean measurement asked for -- "sample the value across
  # frames while we write nothing at all and show it moving under us". Every
  # sample below is taken on a frame this mod did not write, so any delta
  # between consecutive lines is somebody else's write, and the cadence answers
  # "once, or continuously?" without a detour.
  # ---- ONE SHOT, THEN WATCH.  This is both the experiment and the fix.
  #
  # The endpoint was written exactly once, on the settle tick. From here until
  # the player lowers the weapon this mod writes NOTHING, and samples instead.
  # So the log answers "does a single write HOLD, or snap back, and after how
  # many frames" directly, in frames, with dt on every line -- which is the
  # measurement asked for, and which no amount of reading the game's code can
  # produce. Repeating the write every frame would destroy exactly this
  # information, and is also what the player experiences as the fight.
  if wantAds and gAdsBase > 0.0 and not gAdsObserving:
    # THE HOLD. MEASURED 2026-09-06 (fov e0571f641c01, Woods, pact ADS): the
    # ONE-SHOT write of 53.41 into CameraManager._fov was pulled back to the
    # game's own 60.0 in 12 frames -- 57.20, 58.91, 59.60, 59.87 ... an
    # exponential approach, i.e. the game re-drives the field every frame
    # from wherever it is toward ITS target (base - AimDeltaFov). A single
    # write therefore cannot own the value; `CameraManager::SetFov` cannot
    # either (it returns on the null <Camera>@0x70, fact #260). So while the
    # player aims and the game's ramp has settled, the endpoint is
    # re-asserted EVERY FRAME through the same typed FieldRef gate, and the
    # probe below reports what the camera actually shows -- which is the
    # only statement that matters, and which this hold may still lose if the
    # game's step runs AFTER this drain (then the render sits between the
    # two writers; the probe's steady value says which).
    var s = 0.0
    var haveS = false
    if bCamFov.ok:
      a.reset()
      s = callFloat(bCamFov, cam, a)
      haveS = true
    if cfgAdsHoldEveryFrame and cfgAdsWriteFovField and cm != nil and
       haveS and fabsf(s - gAdsPendTarget) > 0.05 and
       fovReadable(cm, int(OffCamMgrFov) + 4):
      var frWhy = 0'i32
      if frStoreF32(frCmFov(), cm, 0'i32, float32(gAdsPendTarget), frWhy) != 0'i32:
        gAdsHoldWrites = gAdsHoldWrites + 1
        if bCamSetFov.ok:
          # The render reads the Camera, not the manager's field; the game
          # copies one to the other on its own schedule, so both are set.
          a.reset()
          addFloat(a, gAdsPendTarget)
          callVoid(bCamSetFov, cam, a)
      elif not gAdsHoldSaid:
        gAdsHoldSaid = true
        warn "FOV: the per-frame hold's typed store was refused with rule " &
             "code " & $frWhy & "; the endpoint is not being held"
    if gHoldProbeN < AdsProbeMax and haveS:
      gHoldProbeN = gHoldProbeN + 1
      let fld = (if cm != nil and fovReadable(cm, int(OffCamMgrFov) + 4):
                   $fovFloatAt(cm, OffCamMgrFov) else: "unreadable")
      info "FOV: hold probe " & $gHoldProbeN & "/" & $AdsProbeMax &
           " -- frame " & $gHoldProbeN & " after the settle write of " &
           $gAdsPendTarget & "; hold re-asserts so far " & $gAdsHoldWrites &
           (if cfgAdsHoldEveryFrame: "" else: " (hold OFF by config)") &
           ". Camera.fieldOfView " & $s & " (read BEFORE this frame's " &
           "re-assert), CameraManager._fov " & fld &
           ", delta-to-our-endpoint " & $fabsf(s - gAdsPendTarget) &
           ", delta-to-game's-own " & $fabsf(s - gAdsBase) & ", dt " & $dt
      if gHoldProbeN == AdsProbeMax:
        info "FOV: HOLD VERDICT after " & $AdsProbeMax & " frames: the camera " &
             "read " & $s & " against our endpoint " & $gAdsPendTarget &
             " and the game's own " & $gAdsBase & " -- " &
             (if fabsf(s - gAdsPendTarget) <= 0.5: "PASS, the hold owns the value"
              elif fabsf(s - gAdsBase) <= 0.5: "FAIL, the game owns it despite " &
                   $gAdsHoldWrites & " re-asserts (its writer runs after this drain)"
              else: "PARTIAL, the render sits between the two writers")
    if haveS:
      gAdsPrev = s
      gCurFov = s
    return
  if gAdsNoFight and wantAds:
    return

  # ---- WHO OWNS THE FIELD OF VIEW RIGHT NOW.
  #
  # See cfgAdsDeferToGame. Leaving ADS drops everything learned about the game's
  # ADS FOV, because the next ADS may be through a different sight and a
  # remembered value would be a plausible wrong number -- the exact failure this
  # whole path exists to remove.
  if not wantAds:
    if gAdsObserving or gAdsBase > 0.0:
      gAdsObserving = false
      gAdsBase = 0.0
      gAdsMoved = false
      gAdsStill = 0
      gAdsObsT = 0.0

  var endpoint = gBaseFov * mult
  if cfgAdsDeferToGame and wantAds and mult != 1.0 and bCamFov.ok:
    if gAdsBase > 0.0:
      # Learned. Our multiplier composes onto the GAME's real ADS FOV.
      endpoint = gAdsBase * mult
    else:
      # Not learned yet. Start, or continue, observing -- and WRITE NOTHING, so
      # for the whole of the game's own aim-in ramp there is exactly one writer.
      a.reset()
      let seenNow = callFloat(bCamFov, cam, a)
      if seenNow <= 0.0:
        return
      if not gAdsObserving:
        gAdsObserving = true
        gHoldProbeN = 0
        gAdsHoldWrites = 0
        gAdsObsT = 0.0
        gAdsMoved = false
        gAdsStill = 0
        gAdsStart = seenNow
        gAdsPrev = seenNow
        # The smoother must not believe it is still sitting where it last wrote,
        # or the ease that follows would start from a stale number.
        gCurFov = seenNow
        gSmFrom = seenNow
        gSmTo = seenNow
        gSmSettled = true
        gLastTarget = 0.0
      gAdsObsT = gAdsObsT + dt
      let step = fabsf(seenNow - gAdsPrev)
      gAdsPrev = seenNow
      gCurFov = seenNow          ## track the game, so a cancelled ADS eases out
                                 ## from where the view actually is
      if step >= cfgAdsSettleEps:
        gAdsMoved = true
        gAdsStill = 0
      elif gAdsMoved:
        # Stillness only counts once motion has been SEEN. Before that it is
        # "the ramp has not started", which is not the same answer.
        gAdsStill = gAdsStill + 1
      if gAdsMoved and gAdsStill >= cfgAdsSettleTicks:
        gAdsObserving = false
        gAdsBase = seenNow
        gAdsLearns = gAdsLearns + 1
        endpoint = gAdsBase * mult
        gAdsPendReport = true
        gAdsPendTarget = endpoint
        gAdsPendGameFov = gAdsBase
        gAdsPendPath = "defer-to-game, settled"

        # ---- INPUT-SIDE INJECTION: write the GAME's OWN field, not the
        # camera's output.
        #
        # The 40-sample probe measured Camera.fieldOfView perfectly stable
        # (delta 0.0 on every frame) while this mod wrote nothing, so there is
        # NO per-frame writer -- the game assigns the ADS value once. What the
        # earlier "78.4% back toward the game's value in one frame" measured was
        # therefore a re-assertion PROVOKED BY OUR WRITE: something notices
        # Camera.fieldOfView no longer agrees with CameraManager._fov and
        # converges it back. If that is the mechanism, then writing _fov itself
        # makes the game converge to OUR number and hold there, which is the
        # input-side injection -- and it is a plain float field write, not a
        # detour, so it costs no RVA row and cannot collide with another hook.
        #
        # Never blind: _fov is read first and must corroborate what the camera
        # already told us, and the write is readback-verified by the helper.
        if cfgAdsWriteFovField and cm != nil and
           fovReadable(cm, int(OffCamMgrFov) + 4):
          let fovField = fovFloatAt(cm, OffCamMgrFov)
          if fovField < 10.0 or fovField > 180.0 or
             fabsf(fovField - gAdsBase) > 2.0:
            # The offset is metadata-confirmed, so a disagreement here is not a
            # bad offset -- it is a different CameraManager, or an ADS fov this
            # mod did not actually observe. Either way it is not a thing to
            # write to. Refuse loudly; the camera write still happens.
            gAdsFieldState = "REFUSED -- CameraManager._fov@0xF8 reads " &
                             $fovField & ", which is not the settled ADS fov " &
                             $gAdsBase & " the camera reported. Not writing a " &
                             "field whose value we cannot corroborate."
            if gAdsFieldRefusals == 0: warn "FOV: " & gAdsFieldState
            gAdsFieldRefusals = gAdsFieldRefusals + 1
          else:
            # `cm` came back from `CameraManager::get_Instance`, so its type is
            # a fact of the call rather than of a pointer we walked to, and
            # admitting its klass here is legitimate rather than circular --
            # the same argument redirect.nim makes for its EasyBundle receiver.
            discard frAdmit(frCmFov(), cm)
            var frWhy = 0'i32
            if frStoreF32(frCmFov(), cm, 0'i32, float32(endpoint), frWhy) !=
               0'i32:
              gAdsFieldWrites = gAdsFieldWrites + 1
              gAdsFieldState = "WROTE CameraManager._fov@+0x" &
                               $frOff(frCmFov()) & " = " & $endpoint &
                               " (was " & $fovField &
                               ") through the typed FieldRef gate"
              if gAdsFieldWrites == 1: info "FOV: " & gAdsFieldState
            else:
              gAdsFieldState = "REFUSED -- the typed store into " &
                               "CameraManager._fov (+0x" & $frOff(frCmFov()) &
                               ") was refused with rule code " & $frWhy &
                               " (1=narrow-into-reference 2=too-wide " &
                               "3=klass-not-admitted 4=receiver 5=bound " &
                               "6=unusable FieldRef). Nothing was written."
              if gAdsFieldRefusals == 0: warn "FOV: " & gAdsFieldState
              gAdsFieldRefusals = gAdsFieldRefusals + 1
        gAdsVerdict = "LEARNED -- the game ramped its own FOV from " &
                      $gAdsStart & " to " & $gAdsBase & " over " &
                      $(gAdsObsT * 1000.0) & " ms with this mod writing " &
                      "nothing; the multiplier x" & $mult & " now composes " &
                      "onto " & $gAdsBase & " for an endpoint of " & $endpoint &
                      " (the old code would have written " & $(gBaseFov * mult) &
                      ", derived from the HIP fov " & $gBaseFov & ")"
        if gAdsLearns == 1: info "FOV: " & gAdsVerdict
      elif gAdsObsT >= cfgAdsObserveCap:
        # Give up honestly and fall back, rather than never applying anything.
        gAdsObserving = false
        gAdsBase = gAdsPrev
        gAdsGiveUps = gAdsGiveUps + 1
        endpoint = gAdsBase * mult
        gAdsPendReport = true
        gAdsPendTarget = endpoint
        gAdsPendGameFov = gAdsPrev
        gAdsPendPath = "defer-to-game, CAP EXPIRED (" &
                       (if gAdsMoved: "never stopped moving"
                        else: "the game never moved Camera.fieldOfView at " &
                              "all -- if this is what the log says, the game " &
                              "does NOT drive ADS through this field and the " &
                              "whole defer strategy is aimed at the wrong " &
                              "writer") & ")"
        gAdsVerdict = "INCONCLUSIVE -- the game's own field of view never " &
                      (if gAdsMoved: "stopped moving" else: "moved at all") &
                      " in " & $(gAdsObsT * 1000.0) & " ms of watching (it " &
                      "read " & $gAdsStart & " at ADS-in and " & $gAdsPrev &
                      " at the cap). Taking " & $gAdsPrev & " as the ADS FOV " &
                      "anyway and saying so; this is NOT a pass."
        if gAdsGiveUps == 1: warn "FOV: " & gAdsVerdict
      else:
        # Still watching. The game owns the field this tick.
        return

  # ---- THE TWO STRATEGIES ARE MUTUALLY EXCLUSIVE, AND THIS IS WHERE.
  #
  # WHAT WENT WRONG IN THE SHIPPED BUILD, exactly: with adsDeferToGame AND
  # enableAdsSmoothing both true, BOTH ran, in sequence. The defer path waited
  # for the game's aim-in ramp to finish, then fell through to the smoother,
  # which saw a changed endpoint and started a SECOND ramp of adsInDuration()
  # (333 ms at rifleAimSpeedZ 3.0) from the game's settled ADS fov to
  # gAdsBase*mult -- a second FOV move, beginning only after the game's aim-in
  # had already visibly completed. Deferring the start of our fight is not the
  # same as not fighting.
  #
  # So: when we are deferring, the ADS-IN direction takes NO ramp of ours at
  # all. The game already performed the ramp; the multiplier is a one-off
  # correction applied to the value it settled on. `enableAdsSmoothing` is
  # INERT for the in-direction and untouched for the out-direction, which the
  # player has consistently reported as fine and which must stay that way --
  # its endpoint is gBaseFov, the game's own hip fov, so both writers agree
  # there and the ramp is invisible.
  let inDirInert = cfgAdsDeferToGame and wantAds and mult != 1.0 and
                   bCamFov.ok and gAdsBase > 0.0
  var target = endpoint
  if inDirInert:
    gCurFov = endpoint
    gSmFrom = endpoint
    gSmTo = endpoint
    gSmT = 0.0
    gSmDur = 0.0
    gSmToAds = true
    gSmSettled = true
    gSmVerified = true    ## the ADS-in report above owns this verdict now
    target = endpoint
  elif not cfgEnableAdsSmoothing:
    gCurFov = endpoint
    gSmSettled = true
  else:
    # A new endpoint starts a new transition FROM WHERE WE ARE, not from the
    # previous endpoint -- so an ADS cancelled half-way through does not snap
    # back before easing out.
    if fabsf(endpoint - gSmTo) > 0.001:
      gSmFrom = gCurFov
      gSmTo = endpoint
      gSmT = 0.0
      gSmToAds = wantAds
      gSmDur = (if wantAds: adsInDuration() else: adsOutDuration())
      gSmSettled = false
      gSmVerified = false
    if not gSmSettled:
      gSmT = gSmT + dt
      var p = 0.0
      if gSmDur > 0.0: p = gSmT / gSmDur
      if p >= 1.0:
        p = 1.0
        gSmSettled = true
        gSmElapsed = gSmT
      gCurFov = gSmFrom + (gSmTo - gSmFrom) * easeAt(p)
    else:
      gCurFov = gSmTo
    target = gCurFov

  # An unchanged multiplier of exactly 1.0 is the camera's own value; writing
  # it every frame would be a call that cannot be observed. Skipped -- but only
  # once the transition has SETTLED there, so the ease back out to the base FOV
  # is written every tick instead of being cut off after one frame. (The old
  # condition compared this multiplier with the previous one, which with
  # smoothing would have terminated the un-ADS ease on its second tick.)
  let atRest = mult == 1.0 and gSmSettled and fabsf(target - gBaseFov) < 0.01
  if atRest and gLastRest:
    return
  gLastRest = atRest
  let sampling = gFovWrites <= 4 or (gFovWrites and 511) == 0
  # ---- DID THE PREVIOUS WRITE SURVIVE THE FRAME?
  #
  # Reading back immediately after a write only proves the setter stored
  # something. It does NOT prove the game is not recomputing the field later
  # in the same frame (the WalkEffector shape, fact #37) -- and a value the
  # game recomputes every frame is a no-op the player sees as "does nothing".
  # So the value is ALSO read at the top of a later tick, before this one
  # writes, and a drift there is reported as CLOBBERED rather than hidden.
  # `gLastTarget == target` USED TO GATE BOTH BRANCHES. That made the detector
  # structurally blind during exactly the transition it was needed for: while a
  # transition runs, `target` changes every tick, so the gate was false on every
  # transition frame and the verdict could only ever be formed at rest. It is
  # gone -- the question "did what we wrote last tick survive the frame" does
  # not depend on what we are about to write this tick.
  if (sampling or not gSmVerified) and bCamFov.ok and gLastTarget > 0.0:
    a.reset()
    let pre = callFloat(bCamFov, cam, a)
    let pd = (if pre > gLastTarget: pre - gLastTarget else: gLastTarget - pre)
    if pd > 0.5:
      gHeldVerdict = "CLOBBERED -- last tick wrote " & $gLastTarget &
                     ", this tick found " & $pre & " before writing. The " &
                     "game recomputes the field between frames; a one-shot " &
                     "write cannot win and the per-frame write is what holds it."
    else:
      gHeldVerdict = "HELD -- " & $pre & " still standing from the previous " &
                     "write of " & $gLastTarget

    # ---- DID THE ADS TRANSITION ACTUALLY ARRIVE?  (CLAUDE.md 9b)
    #
    # This verdict USED TO be formed straight after our own `set_fieldOfView`
    # call, in the same Update tick. That is a read-back of our own write: the
    # setter had just stored the value, so it could only ever say PASS -- and it
    # DID say PASS ("ADS-in transition ended with the camera reading 66.75
    # against an endpoint of 66.75") in the very run where the player was
    # watching the field of view snap somewhere else. A check that cannot fail
    # is the bug.
    #
    # It now runs on the FOLLOWING tick, BEFORE this tick writes, so what it
    # reads is what SURVIVED the frame -- i.e. it can be beaten by the game's
    # own drive, which is the only thing worth asking.
    if cfgEnableAdsSmoothing and gSmSettled and not gSmVerified:
      gSmVerified = true
      let ms = gSmElapsed * 1000.0
      if fabsf(pre - gSmTo) <= 0.5:
        gSmPasses = gSmPasses + 1
        gSmVerdict = "PASS -- " & (if gSmToAds: "ADS-in" else: "ADS-out") &
                     " transition settled on " & $gSmTo & " in " & $ms &
                     " ms, and a FULL FRAME LATER the camera still reads " &
                     $pre & ". Nothing overwrote it."
      else:
        gSmFails = gSmFails + 1
        gSmVerdict = "FAIL -- " & (if gSmToAds: "ADS-in" else: "ADS-out") &
                     " transition settled on " & $gSmTo & " after " & $ms &
                     " ms, but one frame later the camera reads " & $pre &
                     " (delta " & $fabsf(pre - gSmTo) & "). Something else " &
                     "is writing the field of view -- this is the snap the " &
                     "player sees at the end of the transition."
      if gSmPasses + gSmFails == 1:
        info "FOV: first ADS transition verdict: " & gSmVerdict
      info "FOV: transition -- from " & $gSmFrom & " to " & $gSmTo &
           " (game's own ADS fov " &
           (if gAdsBase > 0.0: $gAdsBase else: "not learned") &
           ", hip base " & $gBaseFov & ", mult x" & $mult & "), settled in " &
           $ms & " ms, camera one frame later " & $pre & ", delta " &
           $fabsf(pre - gSmTo)
  gLastTarget = target
  # ---- THE WRITE.
  #
  # PRIMARY: `UnityEngine.Camera::set_fieldOfView` on the camera we are
  # HOLDING -- the one `Camera::get_main` returned and that we captured the
  # base FOV from. This is the value the renderer uses.
  #
  # FALLBACK: `CameraManager::SetFov`. Kept only so a refused prologue verify
  # still does the thing that shipped, and reported as DEGRADED, because its
  # disassembly (quoted at `RvaCamSetFieldOfView`) shows it branches straight
  # to its epilogue when `CameraManager.<Camera>@0x70` is null -- which it is,
  # measured, on this build. Calling it is not writing.
  if bCamSetFov.ok:
    a.reset()
    addFloat(a, target)
    if firstPass: bc "C1 about to CALL Camera::set_fieldOfView @0x525dd30"
    callVoid(bCamSetFov, cam, a)
    if firstPass: bc "C2 set_fieldOfView returned without faulting"
    gWriteRoute = "Camera::set_fieldOfView @0x" & hexs(RvaCamSetFieldOfView) &
                  " on the Camera::get_main camera"
  else:
    a.reset()
    addFloat(a, target)
    if gSetFovArgc == 3:
      addFloat(a, 0.0)   # lerp time: upstream sets the value outright
      addBool(a, true)
    if firstPass: bc "C1 about to CALL CameraManager::SetFov @0x1268d20"
    callVoid(bSetFov, cm, a)
    if firstPass: bc "C2 SetFov returned without faulting"
    gWriteRoute = "DEGRADED: CameraManager::SetFov @0x" & hexs(RvaSetFov3) &
                  " (set_fieldOfView refused) -- inert while <Camera>@0x70 " &
                  "is null"
  gFovWrites = gFovWrites + 1

  # ---- DID IT TAKE? Read the finished state back off the same camera.
  #
  # A negative, falsifiable check: if the rendered FOV is not within half a
  # degree of what was asked for, the write did NOT take, and that is said in
  # the roll-call instead of a write count that only proves a call returned.
  # Sampled for the first few writes and then every 512th, so it is not a
  # per-frame call.
  if sampling and bCamFov.ok:
    a.reset()
    let back = callFloat(bCamFov, cam, a)
    let d = (if back > target: back - target else: target - back)
    if d <= 0.5:
      gWriteTook = gWriteTook + 1
      gWriteVerdict = "PASS -- read back " & $back & " after asking for " &
                      $target & " (base " & $gBaseFov & " x " & $mult &
                      "), via " & gWriteRoute
    else:
      gWriteMissed = gWriteMissed + 1
      gWriteVerdict = "FAIL -- asked for " & $target & ", the camera still " &
                      "reads " & $back & ". The call returned and wrote " &
                      "NOTHING. Route: " & gWriteRoute
    if gWriteTook + gWriteMissed == 1:
      info "FOV: write verdict: " & gWriteVerdict

  # The arrival verdict is NOT formed here. It used to be, immediately after the
  # write above, which made it a read-back of our own store -- see the block
  # before the write, where it now runs one full frame later.
  #
  # One case that block cannot reach: if `gLastTarget` is 0 (nothing was written
  # last tick, e.g. we were observing the game's ramp) there is no survival
  # question to ask, and the verdict stays INCONCLUSIVE rather than defaulting
  # to a pass.
  if cfgEnableAdsSmoothing and gSmSettled and not gSmVerified and
     not bCamFov.ok:
    gSmVerified = true
    gSmVerdict = "INCONCLUSIVE -- the transition to " & $gSmTo &
                 " finished but Camera::get_fieldOfView did not verify, so " &
                 "the rendered value could not be read. Not a pass."
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

proc onScaleValueTyped(f: PatchFrame): TypedResult =
  ## Upstream's `CalculateScaleValueByFovPatch`, as a TYPED PREFIX on the
  ## by-RVA target. The method is `void CalculateScaleValueByFov(float fov)`
  ## (confirmed `il2cpp_resolve.py type 7013`), so there is no float to return
  ## and the old `stopWith($cfgFovScale)` was returning a value a void method
  ## never yields. Suppressing the original outright is what stops the viewmodel
  ## being rescaled as the FOV changes -- the scale field keeps whatever value it
  ## last held rather than tracking the widened FOV.
  ##
  ## `setResultVoid()` says "I mean to suppress this" rather than "I forgot", and
  ## `frameReplace()` only sticks if it succeeded -- otherwise the original runs,
  ## which is the game's own behaviour and the correct failure.
  gScaleHits = gScaleHits + 1
  if f.setResultVoid():
    return frameReplace()
  frameContinue()

proc armScaleFix() =
  if not cfgEnableFovScaleFix:
    gScaleState = "off (enableFovScaleFix is false)"
    return
  if not cfgEnableRvaDetours:
    gScaleState = "gated off (enableRvaDetours is false; the by-RVA detour is " &
                  "not installed until it is turned on deliberately)"
    return
  if not typedPatchesReady():
    gScaleState = "refused (INCONCLUSIVE): the host is ABI revision " &
                  $hostApiSize() & " bytes of HostApi and the typed patch " &
                  "frame wants revision 4. A by-RVA detour is TYPED-only " &
                  "(the JSON patch-by-RVA path is refused by the host, and a " &
                  "by-name JSON fallback is the fatal token-gated route this " &
                  "port exists to avoid), so nothing was armed."
    return
  # No `signatureOf` here, on purpose: it is the by-name IL2CPP lookup that is
  # fatal when USED on this build (fact #198). The shape and prologue are in
  # tgtScaleValue(), derived offline, and the host byte-verifies the prologue
  # against its startup snapshot before it writes a single byte.
  var whyScale = ""
  if hookRva(tgtScaleValue(), onScaleValueTyped, whyScale) == Ok:
    gScaleState = "armed by-RVA (typed prefix, suppresses the rescale) at " &
                  "il2cpp+0x6FC250, prologue verified against the host's " &
                  "startup snapshot and the address confirmed UNIQUE"
  else:
    gScaleState = "refused: " & whyScale

# ---------------------------------------------------------------------------
# Effect 3: SightComponent::get_GetCurrentSensitivity
# ---------------------------------------------------------------------------

proc onScopeSensitivityTyped(f: PatchFrame): TypedResult =
  ## Upstream's `ScopeSensitivityPatch`, as a TYPED PREFIX on the by-RVA target.
  ## `float get_GetCurrentSensitivity()` (arity 0, instance) is REPLACED by the
  ## magnification-table value applied to the optic camera's live field of view.
  ## A prefix that provides a result and suppresses the original is exactly the
  ## "replace the return" upstream does; a postfix would only scale the game's
  ## own answer, which is a different effect.
  ##
  ## The same one caveat the JSON form carried still holds and is written down
  ## rather than implied: this cannot tell WHICH sight is being queried, so it
  ## answers from the optic camera's FOV -- the sight being aimed through -- and
  ## nothing here has ever run against BSG's client.
  gSensHits = gSensHits + 1
  if f.setResultFloat(zoomSensFor(opticFieldOfView())):
    return frameReplace()
  # The setter refused (declared return not a float, or the frame expired):
  # let the original run rather than hand back register residue.
  frameContinue()

proc armScopeSensitivity() =
  if not cfgChangeMouseSensitivity:
    gSensState = "off (changeMouseSensitivity is false)"
    return
  if not cfgEnableRvaDetours:
    gSensState = "gated off (enableRvaDetours is false)"
    return
  if not typedPatchesReady():
    gSensState = "refused (INCONCLUSIVE): the host is ABI revision " &
                 $hostApiSize() & " bytes and the typed patch frame wants " &
                 "revision 4; a by-RVA detour is typed-only, so nothing armed."
    return
  # No `signatureOf` (the fatal by-name lookup); the shape and prologue live in
  # tgtScopeSens() and the host byte-verifies the prologue before writing.
  if not bindOpticCamera():
    gSensState = "refused: the optic camera is unreachable (" &
                 gOpticChainState & "), so the table has no field of view " &
                 "to read and would be answering from nothing"
    return
  var whyScope = ""
  if hookRva(tgtScopeSens(), onScopeSensitivityTyped, whyScope) == Ok:
    gSensState = "armed by-RVA (typed prefix, replaces with the magnification " &
                 "table) at il2cpp+0x104A140, " & gOpticChainState
  else:
    gSensState = "refused: " & whyScope

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

# ---------------------------------------------------------------------------
# The scaling on the typed path (the only path now: the by-name JSON form was
# removed with the by-name targets, because using it on this build is fatal)
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
  if not cfgEnableRvaDetours:
    gAimSensState = "gated off (enableRvaDetours is false)"
    return
  # TYPED-ONLY, by RVA. The old code called `signatureOf` first (the by-name
  # IL2CPP lookup that is fatal when USED, fact #198) and fell back to a by-name
  # JSON postfix (fatal for the same reason). Both are gone. The shape
  # (instance, no args, returns float) and prologue are in tgtAimSens(), derived
  # offline from `il2cpp_resolve.py type 6835`, and the host byte-verifies the
  # prologue against its startup snapshot before writing.
  if not typedPatchesReady():
    gAimSensState = "refused (INCONCLUSIVE): the host is ABI revision " &
                    $hostApiSize() & " bytes and the typed patch frame wants " &
                    "revision 4; a by-RVA detour is typed-only, so nothing " &
                    "armed. There is deliberately no by-name JSON fallback -- " &
                    "it is the fatal token-gated route this port exists to avoid."
    return
  var whyAim = ""
  if hookReturnRva(tgtAimSens(), onAimingSensitivityTyped, whyAim) == Ok:
    gAimSensTyped = true
    gAimSensState = "armed by-RVA (typed postfix) at il2cpp+0x7773F0, scaling " &
                    "the original's result by " & $cfgNonOpticSensMulti
  else:
    # The host refuses a postfix on two shapes -- a value-type return wider than
    # a register, and a compiled call needing more than four register slots --
    # and says which; neither should apply to a no-arg float getter.
    gAimSensState = "refused: " & whyAim

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
    threadId: int64    ## the thread the drain last fired on ("mainThreadId")
    stalled: bool      ## the drain has stopped and the host is standing in

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
  result.threadId = int64(asInt(field(raw, "mainThreadId"), 0))
  result.stalled = asBool(field(raw, "stalled"), false)

var gDriverState = "not attempted"
var gDriverIsEveryMain = false
var gDriverThreadId = 0'i64
var gDriverFirings = 0

var gFovTickInflight = 0
  ## The self-disable signal. Incremented at the TOP of a driver tick and reset
  ## to 0 only AFTER `applyFov` RETURNS. Every normal early return inside
  ## `applyFov` still returns, so it resets. A hard fault inside `applyFov` is
  ## caught by the host's SEH guard and control goes back to the host, NOT to the
  ## line after `applyFov` -- so the reset is skipped and the next tick sees the
  ## counter still raised. `MaxFovFaults` consecutive skipped resets means the
  ## body faulted that many ticks running, and the write disables itself.
const MaxFovFaults = 8

proc fovSelfDisabled(): bool =
  ## Shared entry gate for the driver. Trips the kill switch when the inflight
  ## counter shows `MaxFovFaults` ticks in a row where `applyFov` did not return.
  if gFovDisabled:
    return true
  if gFovTickInflight >= MaxFovFaults:
    gFovDisabled = true
    warn "FOV: SELF-DISABLED -- the per-frame write did not return cleanly on " &
         $MaxFovFaults & " ticks running (a caught fault storm). The FOV write " &
         "is OFF for the rest of this run; set enableFovWrite off and read the " &
         "breadcrumb file to see which hop faulted."
    bc "X1 FOV write self-disabled after a fault storm"
    return true
  result = false

var gUnityThreadId = 0'i64
  ## The thread the host's drain last fired ON, as the host reports it in
  ## `aowlspt.host::main_thread`.`mainThreadId`. Zero means "not established".
var gWrongThreadTicks = 0'i64
var gWrongThreadSaid = 0'i64
var gLastWrongThreadId = 0'i64
var gThreadGateState = "not attempted"

proc onUnityThread(): bool =
  ## THE CHECK THAT CAN FAIL. It asks, of the FINISHED state -- the thread this
  ## callback is actually executing on, right now -- "is this the thread the
  ## host's drain fires on?", and it can answer no.
  ##
  ## MEASURED, crash `Crash_2026-09-02_211541986` (and the identical one at
  ## 20:43): this mod's `everyMain` tick ran on the HOST's own thread and
  ## called `UnityEngine.Input::GetKey`, whose native body in UnityPlayer
  ## (`+0x58CF70`) fetches a global manager pointer and dereferences it at
  ## `+0x4A0` with NO null test. The pointer was NULL, rax=0, and the client
  ## died 8.7 s after boot with 15 frames of `fov` on the stack.
  ##
  ## Why the old gate could not catch it. `armFovDriver` asked the host once,
  ## at arm time, whether the drain was `bound` -- and `bound` is a LATCH: the
  ## host sets it the first time the drain fires and never clears it. The host
  ## then, by design, falls back to running queued main-thread work on its own
  ## thread whenever the drain goes quiet for 2 s (`aowlspt-host.log`:
  ## "the main-thread drain has not fired for 2s with work queued; running it
  ## on the host thread until it comes back"). So between "the drain has fired
  ## once" and "the drain is firing now" there is a window -- the whole of
  ## early boot, and any hitch afterwards -- in which a `bound` gate says yes
  ## and the callback lands somewhere a Unity call is illegal. An arm-time
  ## check of a latch is a check that cannot fail.
  ##
  ## Cost: zero host calls on the good path. The host is re-asked only when the
  ## observed thread is NOT the one already established, which is exactly the
  ## case we are refusing anyway, and it lets the answer recover by itself if
  ## the drain migrates to a different thread later.
  let tid = currentThreadId()
  if gUnityThreadId != 0'i64 and tid == gUnityThreadId:
    return true
  let mt = askMainThread()
  if mt.ok and mt.threadId != 0'i64:
    gUnityThreadId = mt.threadId
  if gUnityThreadId != 0'i64 and tid == gUnityThreadId:
    gThreadGateState = "on Unity's drain thread (" & $tid & ")"
    return true
  # Refuse. Three-state, not two: say WHICH of "the host cannot tell us" and
  # "the host told us and this is the wrong thread" happened.
  gWrongThreadTicks = gWrongThreadTicks + 1'i64
  gLastWrongThreadId = tid
  gThreadGateState =
    (if gUnityThreadId == 0'i64:
       "REFUSED: the host has not established which thread its main-thread " &
       "drain fires on (mainThreadId=0), so there is no thread this tick " &
       "could be shown to be on. INCONCLUSIVE is not a pass"
     else:
       "REFUSED: this tick is on thread " & $tid & ", the host's drain fires " &
       "on thread " & $gUnityThreadId & " (drain stalled=" &
       (if mt.stalled: "true" else: "false") & ")") &
    " -- " & $gWrongThreadTicks & " tick(s) refused so far"
  # Loud, then decaying, exactly like `noCamera`: 1, 250, 2500, 25000.
  if gWrongThreadTicks == 1'i64 or gWrongThreadTicks == 250'i64 or
     gWrongThreadTicks == 2_500'i64 or gWrongThreadTicks == 25_000'i64:
    gWrongThreadSaid = gWrongThreadSaid + 1'i64
    warn "FOV: REFUSED a driver tick on the WRONG THREAD -- " &
         gThreadGateState & ". Nothing was called into the engine. This is " &
         "the crash of 2026-09-02: Input::GetKey and Camera/SetFov are " &
         "main-thread-only and their native bodies dereference a global " &
         "manager with no null test, so running here is an ACCESS VIOLATION, " &
         "not a wrong answer. The host runs queued main-thread work on its " &
         "own thread while its drain is stalled; this mod waits instead."
    bc "T3 refused a driver tick on the wrong thread"
  result = false

proc onFovTick(payload: string): string =
  ## The `everyMain` driver. One firing per drain.
  ##
  ## The thread id is recorded rather than assumed: the whole claim behind this
  ## path is "this ran where a Unity write is legal", and the number is the
  ## only evidence for it available from inside a mod. It is printed next to
  ## the host's own answer so the two can disagree in public.
  gDriverFirings = gDriverFirings + 1
  if fovSelfDisabled():
    return ""
  # BEFORE anything that can reach the engine, including the T1 breadcrumb that
  # claims we are about to call it. A tick that is not on Unity's thread does
  # not get to say it tried.
  if not onUnityThread():
    return ""
  if gDriverFirings == 1:
    # The first tick ONLY. This is suspect (a) on the coordinator's list: the
    # RVAs are prologue-verified but have never been EXECUTED, and a verified
    # prologue proves the bytes match, not that calling them here is legal.
    # If the run dies with T1 present and T2 absent, the fault is inside
    # `applyFov` on its first pass and the sub-crumbs A*/B* say where.
    bc "T1 first everyMain tick, about to call applyFov"
  gDriverThreadId = currentThreadId()
  # RAISE the inflight signal, call, LOWER it. If applyFov faults the host SEH
  # guard returns control below this call site, so the reset never runs and the
  # counter climbs toward MaxFovFaults -- that is the whole self-disable.
  gFovTickInflight = gFovTickInflight + 1
  applyFov()
  gFovTickInflight = 0
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
    gDriverState = "NOT INSTALLED: enableFovWrite was turned OFF (it defaults " &
                   "ON now). No driver was registered and applyFov is " &
                   "unreachable this run. The static RVAs are still verified " &
                   "and reported above."
    gFovState = "NOT INSTALLED: enableFovWrite was turned off"
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
  # The camera, on its own line, because it is the receiver every write needs
  # and because a zero write count is only interpretable next to it.
  case gCamAcq
  of ccLive:
    success "    camera: LIVE (static CameraManager::get_Instance; no host " &
            "export involved)"
  of ccBroken:
    warn "    camera: BROKEN -- in a game and still no usable camera after " &
         $gCamBrokenFrames & " frames: " & gCamWhy
  of ccAbsent:
    info "    camera: none, and no evidence of being in a game -- " &
         "INCONCLUSIVE, not a pass (" & gCamWhy & ")"
  of ccUnknown:
    info "    camera: never asked for (the per-frame path never ran)"
  info "    aiming input: " & gAimSourceState
  info "    write route: " & gWriteRoute
  info "    DID IT TAKE (read back off the camera, not a self-comparison): " &
       gWriteVerdict & "  [took " & $gWriteTook & ", missed " & $gWriteMissed &
       "]"
  info "    DID IT HOLD (sampled a tick later, before the next write): " &
       gHeldVerdict
  info "    DID THE ADS TRANSITION ARRIVE (camera read back on the tick the " &
       "ease ended): " & gSmVerdict & "  [passed " & $gSmPasses & ", failed " &
       $gSmFails & "]"
  info "    smoothing: " &
       (if not cfgEnableAdsSmoothing: "OFF -- the FOV steps in one frame"
        else: "in " & $(adsInDuration() * 1000.0) & " ms / out " &
              $(adsOutDuration() * 1000.0) & " ms, " &
              (if cfgAdsSmoothLinear: "linear" else: "smoothstep")) &
       "; base FOV " & $gBaseFov & ", current " & $gCurFov
  info "    who drives the aim-in: " &
       (if not cfgAdsDeferToGame:
          "THIS MOD -- adsDeferToGame is off, so our ramp races the game's own"
        else:
          "THE GAME (adsDeferToGame on); this mod writes nothing until the " &
          "game's ramp settles, and the ADS-IN direction takes no ramp of " &
          "ours afterwards. " & $gAdsLearns & " settled, " & $gAdsGiveUps &
          " gave up. " & gAdsVerdict)
  # Absence of ADS-in lines must mean one thing only, and the log has to say
  # which. A silent instrument is what let the original defect survive.
  info "    the game's ADS fov is a SUBTRACTION, not a scale -- measured: " &
       "CameraManager.AimDeltaFov is a LITERAL const 15.0 and OpticsFov a " &
       "LITERAL const 35.0 (attrs 0x8056, no storage, nothing to write). " &
       "hip 75.0 - 15.0 = 60.0 against a live-measured settled ADS fov of " &
       "60.00136. So 'base x nonOpticFovMulti' was the wrong SHAPE of model, " &
       "which is exactly the player's 'the scale we zoom-in ads fov with is " &
       "wrong'. Applying the multiplier to the settled value gets the right " &
       "number; it does not get ownership of the field."
  info "    input-side write: " & gAdsFieldState & " (" & $gAdsFieldWrites &
       " written, " & $gAdsFieldRefusals & " refused). Camera.fieldOfView is " &
       "written ONCE per aim-in, on the tick the game's own ramp settles, and " &
       "never again while aiming -- so the 'hold probe' lines that follow " &
       "measure whether a single write survives, in frames."
  info "    the honest knob: because the game computes ADS fov as " &
       "base - AimDeltaFov (75.0 - 15.0 = 60.0, matching the measured " &
       "60.00136), a MULTIPLIER is the wrong user-facing shape -- x0.89 means " &
       "different things at different base FOVs and cannot be reasoned about. " &
       "A DELTA ('ADS fov = base - 15 - X') matches how the game models it " &
       "and is predictable. The multipliers are kept for now because they are " &
       "what the deployed config and the settings UI already carry; changing " &
       "the knob is a separate, deliberate change and is NOT smuggled in here."
  if gAdsNoFight:
    warn "    ADS field of view: CONCEDED after " & $gAdsConsecFails &
         " lost transitions. Hip FOV still applied; opticFovMulti and " &
         "nonOpticFovMulti are INERT while aiming. This is a DECLINE, said " &
         "out loud, not a silent no-op."
  info "    aim-ins seen this run: " & $gAdsIns &
       (if gAdsIns == 0:
          " -- SO THERE IS NOTHING TO REPORT. This is 'the player never " &
          "aimed down sights while the mod was armed', NOT 'the feature is " &
          "off'; the feature state is the line above. Every aim-in logs a " &
          "'transition ADS-IN' line on the aiming edge, before any gate."
        else: " (" & $gSmPasses & " survived a frame, " & $gSmFails &
              " did not)")
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
    # The per-tick thread gate, reported whether or not it ever refused, so
    # that "it never fired wrong" and "nobody looked" are distinguishable.
    if gWrongThreadTicks > 0'i64:
      warn "    thread gate: " & gThreadGateState & " (last wrong thread " &
           $gLastWrongThreadId & ", said " & $gWrongThreadSaid & " time(s)). " &
           "Those ticks made NO engine call. Before this gate existed they " &
           "were an access violation inside UnityPlayer's Input::GetKey."
    else:
      info "    thread gate: " & gThreadGateState & " -- 0 tick(s) refused"
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

proc expectRefused(what, why: string): int =
  ## One negative. `why` is what `rvaSpecOf` said; a non-empty `why` is the
  ## refusal, so a PASS here is the description being rejected.
  if why.len > 0:
    guardOk what & " -- refused: " & why
    result = 0
  else:
    guardBad what & " was ACCEPTED. The by-RVA description is being built " &
             "from input that is wrong, so every spec this mod hands the " &
             "host is unchecked on the way out."
    result = 1

proc checkRvaPatchTargets(): int =
  ## The by-RVA descriptions, checked STRUCTURALLY, with no game and no host.
  ##
  ## Three negatives and one positive, and the split matters. What this CAN
  ## establish is that `rvaSpecOf` refuses a malformed description and that the
  ## three real targets serialise to exactly the spec strings that were derived
  ## offline -- byte for byte, including the prologue, so a typo in a hex digit
  ## is a failure here rather than a host refusal in a raid.
  ##
  ## What it CANNOT establish, and does not claim: that the addresses are
  ## unique, that the prologues match the installed GameAssembly.dll, or that
  ## nothing else has detoured them. Those are answered by the HOST's own
  ## gates, against the real module and the real name index, and the host
  ## proves its gates can say no with its own four-probe self-check (see
  ## `patchrva.nim`) rather than being taken on trust from here.
  result = 0
  var why = ""

  # NEGATIVE 1: a prologue too short to identify anything.
  var shortPro = tgtAimSens()
  shortPro.prologue = @[0x40'u8, 0x53'u8, 0x48'u8]
  discard rvaSpecOf(shortPro, why)
  result = result + expectRefused("a 3-byte prologue", why)

  # NEGATIVE 2: a shape that declares no return.
  var badShape = tgtAimSens()
  badShape.shape = "if"
  discard rvaSpecOf(badShape, why)
  result = result + expectRefused("the shape \"if\" (no return letter)", why)

  # NEGATIVE 3: the address the spec grammar reserves for "not code".
  var zeroRva = tgtAimSens()
  zeroRva.rva = 0'u32
  discard rvaSpecOf(zeroRva, why)
  result = result + expectRefused("an RVA of 0", why)

  # POSITIVE: the three real ones, against the strings derived offline. Only
  # meaningful because the three negatives above passed.
  let wantAim = "FirearmController::get_AimingSensitivity" &
                "@0x7773F0/i>f!40534883EC20488B11488BD9488B82C8"
  let wantScope = "EFT.InventoryLogic.SightComponent::get_GetCurrentSensitivity" &
                  "@0x104A140/i>f!40534883EC20803D4817070600488BD9"
  let wantScale = "EFT.Player::CalculateScaleValueByFov" &
                  "@0x6FC250/if>x!F30F5C0D40A6EB05F30F1005A09DEB05"
  let gotAim = rvaSpecOf(tgtAimSens(), why)
  if gotAim == wantAim:
    guardOk "tgtAimSens serialises to the derived spec exactly"
  else:
    guardBad "tgtAimSens produced " & (if gotAim.len == 0: "a refusal (" & why &
             ")" else: gotAim) & ", wanted " & wantAim
    result = result + 1
  let gotScope = rvaSpecOf(tgtScopeSens(), why)
  if gotScope == wantScope:
    guardOk "tgtScopeSens serialises to the derived spec exactly"
  else:
    guardBad "tgtScopeSens produced " & (if gotScope.len == 0: "a refusal (" &
             why & ")" else: gotScope) & ", wanted " & wantScope
    result = result + 1
  let gotScale = rvaSpecOf(tgtScaleValue(), why)
  if gotScale == wantScale:
    guardOk "tgtScaleValue serialises to the derived spec exactly"
  else:
    guardBad "tgtScaleValue produced " & (if gotScale.len == 0: "a refusal (" &
             why & ")" else: gotScale) & ", wanted " & wantScale
    result = result + 1

  # The arity the host will look each name up at, from the shape rather than
  # from the name. Wrong here means the name/RVA cross-check asks the index a
  # question about a different overload and the patch is refused as UNKNOWN.
  if rvaArity(tgtAimSens()) == 0 and rvaArity(tgtScopeSens()) == 0 and
     rvaArity(tgtScaleValue()) == 1:
    guardOk "declared arities 0/0/1 match the index keys measured offline " &
            "(get_AimingSensitivity/0, get_GetCurrentSensitivity/0, " &
            "CalculateScaleValueByFov/1)"
  else:
    guardBad "a declared shape implies an arity the offline index does not " &
             "have a key for; the host would refuse the patch as UNKNOWN"
    result = result + 1

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
  # --- 1. the prologue verifier, PROVED to be able to say no ---------------
  #
  # This replaces the old stated-kinds check, which exercised `ensureCall`
  # and is gone with it. That check is not merely relocated -- it could only
  # run through `il2cpp_method_get_return_type`, i.e. through the same gated
  # export surface that killed the client, so keeping it would have meant
  # keeping the fatal path alive inside a self-test.
  #
  # What replaces it is deliberately a NEGATIVE, per CLAUDE.md 9b: not "the
  # seven RVAs verified" (which passes trivially on any DLL the bytes were
  # copied from, and is what `bindFovStatics` already reports), but "the
  # verifier REFUSES a prologue that does not match". If this cannot fail,
  # every 16/16 result printed anywhere in this mod is worthless.
  #
  # The wrong-prologue probe uses a REAL, verified RVA with one byte
  # corrupted, so a pass cannot be explained by the address being bad.
  #
  # ORDER MATTERS HERE, and getting it wrong would reproduce exactly the
  # defect this check exists to catch. `bindAtRva` refuses with "GameAssembly
  # .dll is not bound, so there is no imagebase to add an RVA to" LONG before
  # it compares a byte, so running the negative with no runtime open would
  # see a refusal, call it a pass, and prove nothing at all. So: no runtime,
  # no verdict.
  if not rtOpen:
    warn "  INCONCLUSIVE: no GameAssembly.dll is bound, so neither the " &
         "prologue verifier nor the seven static RVAs could be exercised " &
         "against anything. This is not a pass. Set selfTestRuntime to an " &
         "absolute path to a GameAssembly.dll to get a real verdict."
  else:
    var bogus = ProCamInstance
    # Flip the first byte: "48 83 ..." -> "49 83 ...". Same length, same shape,
    # one byte different from the DLL.
    bogus[1] = '9'
    let refused = bindAtRva("CameraManager::get_Instance (DELIBERATELY WRONG " &
                            "prologue -- this must be refused)",
                            RvaCamInstance, bogus, noKinds(), fkPtr, true)
    if refused.ok:
      guardBad "bindAtRva ACCEPTED a prologue that differs from the installed " &
               "GameAssembly.dll in its first byte. Every \"prologue-verified " &
               "16/16\" line this mod prints is therefore unfalsifiable, and " &
               "a stale RVA after a Tarkov update would bind silently."
      inc result
    else:
      guardOk "bindAtRva refuses a one-byte-wrong prologue at a known-good " &
              "RVA -- " & refused.why

    # And the positive, which is only meaningful because the negative above
    # passed.
    if bindFovStatics():
      guardOk "all seven static RVAs prologue-verified 16/16 against the " &
              "installed GameAssembly.dll: get_Instance, SetFov, GetKey, " &
              "GetKeyDown, get_fieldOfView, get_CurrentScope, get_IsOptic"
    else:
      guardBad "at least one of the seven static RVAs did not verify: " &
               gFovState
      inc result


  if not rtOpen:
    warn "  guards not checked: no runtime is bound, so there is nothing to " &
         "ask. Set selfTestRuntime to exercise them."
    return
  if gNoDomain:
    warn "  guards not checked: the runtime loaded but il2cpp_init gave no " &
         "domain, so a by-name lookup would walk structures that were never " &
         "built -- measured to be a 0xC0000005, not a nil."
    return

  # --- 2. the placeholder gate, which could not fail until today ------------
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

  # --- 3. no by-name route survives in the frame path -----------------------
  #
  # `gByNameRefusals` counts every time `signatureOf` turned back. The frame
  # path no longer calls it at all, so this is a statement about the REPORT
  # path only, and it is printed rather than asserted because a non-zero
  # count there is correct behaviour.
  info "  by-name lookups refused so far: " & $gByNameRefusals &
       " (the frame path makes none -- three field reads and four verified " &
       "RVA calls)"

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
  reportBinding("CameraManager::get_Instance (verified static RVA)",
                bCamInstance)
  reportBinding("CameraManager::SetFov (verified static RVA)", bSetFov)
  reportBinding("Input::GetKey (verified static RVA)", bGetKey)
  reportBinding("Input::GetKeyDown (verified static RVA)", bGetKeyDown)
  reportBinding("Camera::get_fieldOfView (verified static RVA)", bCamFov)
  reportBinding("Camera::set_fieldOfView (verified static RVA -- THE WRITE)",
                bCamSetFov)
  reportBinding("ProceduralWeaponAnimation::get_CurrentScope (verified " &
                "static RVA)", bCurrentScope)
  reportBinding("SightNBone::get_IsOptic (verified static RVA)", bIsOptic)
  info "    GameWorld.MainPlayer -- FIELD READ @0x" &
       hexs(OffGameWorldMainPlayer) & ", no lookup"
  info "    Player.ProceduralWeaponAnimation -- FIELD READ @0x" &
       hexs(OffPlayerPwa) & ", no lookup"
  info "    ProceduralWeaponAnimation._isAiming -- FIELD READ @0x" &
       hexs(OffPwaIsAiming) & ", no lookup"
  info "    optic detection: " & gOpticChainState
  # The by-name probes that used to print here are GONE, and their absence is
  # the report. `probeMember` was informational -- it asked the live runtime
  # whether a name was declared on a type -- but every line it printed for
  # this chain was actively misleading now that nothing is resolved by name:
  # it reported `EFT.GameWorld::get_MainPlayer` and
  # `UnityEngine.Camera::get_fieldOfView` as "NO NAME ... not declared on that
  # type" while both are reached correctly, one by field read and one by
  # verified RVA. A report that says a working path is missing is worse than
  # no report.
  #
  # `probeMember` itself is kept, and is still used for the two by-name
  # EFFECTS below that have not been ported to a verified RVA; it refuses
  # client-side in `signatureOf` and says so.

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

  info "  the by-RVA targets, serialised and checked against the offline " &
       "derivation:"
  let badTargets = checkRvaPatchTargets()
  if badTargets > 0:
    error "  " & $badTargets & " by-RVA target check(s) failed; the host " &
          "would be handed a description that does not say what it means"
    return ErrGeneric

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
         " calls, none of which reached a write -- camera: " & gCamWhy &
         ". That is the guard: what the effect costs when there is nothing " &
         "to do, and it is INCONCLUSIVE about whether the effect works."
  info "  for comparison, docs/PERF.md measures one boxed host call at " &
       "950-1235 ns and one bound call at 6-10 ns; the eight-call chain this " &
       "replaces was about 8 us of marshalling per frame"
  result = Ok

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

var gElapsedMs = 0'i64

proc onSettingsHotApply(key: string) =
  ## fov is client-side, so its `/aowlspt/settings/<guid>` route is registered
  ## into nothing and the handlers above never run in the client. Without this
  ## an F12 edit persists to config.json and the live FOV keeps the value it
  ## was loaded with until the next launch -- a slider that moves and changes
  ## nothing. Same call the route handler makes: ONE apply path, not two.
  ##
  ## Re-reading the config IS enough for the multipliers: `applyFov` reads the
  ## `cfg*` globals every frame and never caches them, so `loadConfig` alone
  ## puts a new multiplier in force on the next frame. What it is NOT enough
  ## for is anything decided at load -- which driver was installed, and whether
  ## one was installed at all -- and those must say "restart" rather than let
  ## the caller assume the re-read did something.
  ##
  ## This proc lives HERE, below `gFovState`/`gDriverState`/`armed`, rather
  ## than next to the route handlers it mirrors, because it now reports the
  ## arming state and those are declared later in the file.
  loadConfig()
  if key == "enableFovWrite" or key == "verifyHooksByName" or
     key == "hookFrameDriver" or key == "deferUntilUnityThread":
    settingAppliesOnRestart("this key is read once, at load, to decide what " &
                            "gets installed; re-reading the config cannot " &
                            "install or remove a driver mid-run")
    return
  if not cfgEnableFovWrite:
    settingIgnored("the FOV write is not installed this run -- " & gDriverState)
    return
  if not armed(gFovState):
    settingIgnored("the FOV effect is not armed -- " & gFovState &
                   " (last camera reason: " & gCamWhy & ")")
    return
  settingApplied("now writing optic x" & $cfgOpticFovMulti & ", unmagnified x" &
                 $cfgNonOpticFovMulti & ", base FOV clamped to " &
                 $cfgMinBaseFov & ".." & $cfgMaxBaseFov & "; sensitivity " &
                 (if cfgChangeMouseSensitivity: "scaled" else: "untouched"))

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
  onSettingsApplied(onSettingsHotApply)
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
  # THE FORMULA, in the log, so the calibration can be checked rather than
  # believed. See the comment block above `gCurFov`.
  info "config: FOV formula -- target = BASE_FOV x mult, where mult is 1.0 " &
       "at the hip, x" & $cfgOpticFovMulti & " aiming through an optic, x" &
       $cfgNonOpticFovMulti & " aiming without one, and the toggle-zoom " &
       "multiplier composes ON TOP. Every multiplier is applied to the " &
       "captured BASE, never to the previous frame's value."
  if cfgOpticFovMulti > 0.999 and cfgOpticFovMulti < 1.001:
    warn "config: opticFovMulti is 1.0, so aiming THROUGH AN OPTIC will " &
         "change the field of view by exactly nothing. That is a working " &
         "mod producing an invisible result, not a broken one -- if ADS " &
         "'does nothing' with a scope equipped, this setting is why."
  # Two mutually-exclusive aim-in strategies must never be left BOTH enabled
  # and silently sequenced -- that is the shipped defect. The resolution is
  # stated out loud at load, so the config cannot be misread as "both apply".
  if cfgAdsDeferToGame:
    if cfgEnableAdsSmoothing:
      warn "config: adsDeferToGame AND enableAdsSmoothing are BOTH on. These " &
           "are two different aim-in strategies and they are NOT combined. " &
           "RESOLVED: adsDeferToGame wins for the ADS-IN direction, which " &
           "takes NO ramp of ours -- the game performs the ramp and our " &
           "multiplier is applied once to the value it settles on. " &
           "enableAdsSmoothing still governs the ADS-OUT direction only " &
           "(out endpoint = the hip FOV, which the game agrees with, and " &
           "which the player reports as correct). Set adsDeferToGame off to " &
           "get the old both-ways behaviour back."
    else:
      info "config: aim-in strategy = defer to the game; aim-out is a step " &
           "(enableAdsSmoothing is off)."
  if cfgEnableAdsSmoothing:
    info "config: ADS smoothing ON -- in " & $(adsInDuration() * 1000.0) &
         " ms, out " & $(adsOutDuration() * 1000.0) & " ms, " &
         (if cfgAdsSmoothLinear: "linear" else: "smoothstep") & " easing, " &
         (if cfgUseAimSpeedsForFov:
            "durations taken from rifleAimSpeedZ / unAimSpeedZ as 1/speed " &
            "(these two settings are WIRED now; the other seven aim speeds " &
            "are not, because nothing here reads the weapon class)"
          else: "durations from adsSmoothTime / unAdsSmoothTime")
  else:
    warn "config: ADS smoothing is OFF -- the field of view will STEP " &
         "between hip and ADS in a single frame, which is the behaviour the " &
         "smoothing was added to replace."
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
  info "INERT config (read, printed, NEVER written to the game): camera " &
       "offset keys " & cfgCameraIncreaseOffsetKey & " / " &
       cfgCameraDecreaseOffsetKey & ", rifle Z " & $cfgRifleCameraZOffset &
       ", pistol Z " & $cfgPistolCameraZOffset
  if cfgEnableFovScaleFix:
    info "config: FOV scale fix requested at " & $cfgFovScale
  info "INERT config: camera speeds rifle " & $cfgRifleCameraSpeed & ", pistol " &
       $cfgPistolCameraSpeed & ", optic " & $cfgOpticCameraSpeed &
       "; un-aim X/Y " & $cfgUnAimSpeedX & "/" & $cfgUnAimSpeedY &
       " (unAimSpeedZ " & $cfgUnAimSpeedZ & " is NOT inert -- it sets the " &
       "ADS-out FOV transition time when useAimSpeedsForFovSmoothing is on)"
  info "INERT config: ADS camera distance optic " & $cfgOpticCameraDistanceOffset &
       ", non-optic " & $cfgNonOpticCameraDistanceOffset & ", pistol " &
       $cfgPistolCameraDistanceOffset & "; left shoulder rifle " &
       $cfgRifleLeftShoulderOffset & ", pistol " & $cfgPistolLeftShoulderOffset
  info "INERT config: aim speeds rifle X/Y " & $cfgRifleAimSpeedX & "/" &
       $cfgRifleAimSpeedY & ", pistol " & $cfgPistolAimSpeedX & "/" &
       $cfgPistolAimSpeedY & "/" & $cfgPistolAimSpeedZ &
       " -- rifleAimSpeedZ " & $cfgRifleAimSpeedZ & " is WIRED (ADS-in FOV " &
       "transition time = 1/speed). The pistol table stays inert because " &
       "nothing in this mod reads the weapon class, so picking between the " &
       "two tables would be a guess about behaviour."
  info "INERT config: camera XY offsets rifle " & $cfgRifleCameraXOffset & "/" &
       $cfgRifleCameraYOffset & ", pistol " & $cfgPistolCameraXOffset & "/" &
       $cfgPistolCameraYOffset
  info "config: toggle-zoom un-aimed FOV x" & $cfgUnaimedToggleZoomMulti &
       " (APPLIED)" &
       (if cfgCancelZoomOnUnAds: ", cancelled on un-ADS (APPLIED)" else: "")
  info "INERT config: toggle-zoom SENSITIVITY optic x" &
       $cfgOpticToggleZoomSensMulti & ", aimed x" &
       $cfgNonOpticToggleZoomSensMulti & ", un-aimed x" &
       $cfgUnaimedToggleZoomSensMulti &
       (if cfgZoomOnHoldBreath: "; zoomOnHoldBreath" else: "")
  # The note this replaces said the TOGGLE-ZOOM SETTINGS were not applied.
  # That was false and had been for a while: the toggle-zoom key, holdToZoom,
  # cancelZoomOnUnAds and all three toggle-zoom FOV multipliers are read in
  # `pollZoomKey` and multiplied into `mult` in `applyFov`. Only the
  # toggle-zoom SENSITIVITY multipliers are inert. A note that indicts the
  # wrong knobs is worse than none: it made a working feature read as dead.
  info "note: every line above prefixed INERT is read and printed and NEVER " &
       "reaches the game -- there is no write path for it in this build, and " &
       "changing it will do nothing. The FOV multipliers, the toggle-zoom " &
       "key and its FOV multipliers, the five ADS-smoothing settings " &
       "(enableAdsSmoothing, adsSmoothTime, unAdsSmoothTime, " &
       "useAimSpeedsForFovSmoothing, adsSmoothLinear) plus rifleAimSpeedZ " &
       "and unAimSpeedZ, enableFovScaleFix and the sensitivity " &
       "table are the ones with a write path. minBaseFov/maxBaseFov are not " &
       "writable AT ALL: GameSettingsGroup.MIN/MAX_FIELD_OF_VIEW are C# " &
       "consts (attrs 0x8056, LITERAL) inlined at every use with no storage " &
       "to write -- they only sanity-swap each other here."
  Ok

## Deferral state. See `onUpdate`.
var gPending = false
var gPendingMs = 0'i64
var gPollMs = 0'i64
var gDeferSaid = false
var gInertSaid = false

proc anyFovEffectEnabled(): bool =
  ## Does this run have ANY effect to arm?
  ##
  ## Every effect in this mod is one of three flags: `enableFovWrite` drives the
  ## per-frame FOV write (and, through `applyFov`, the zoom poll); `enableFovScaleFix`
  ## arms the viewmodel-scale patch; `changeMouseSensitivity` arms both sensitivity
  ## patches. With all three OFF there is nothing to arm and nothing to drive.
  ##
  ## `verifyHooksByName` is DELIBERATELY not in this set. `onUpdate` runs only on the
  ## client (it early-returns on every other side), and on the client every `watch`
  ## declines outright -- a by-name host detour is fatal when USED (facts #198/#145) --
  ## so the diagnostic counts nothing here regardless. Letting it trigger the arm would
  ## pay the one-time ~4.3 ms `onWorldReady` cost (openRuntime + seven by-name type
  ## resolves + seven prologue verifies + four arm procs that all immediately no-op) to
  ## produce a page of "watch DECLINED" lines and nothing else. Measured: with all
  ## three effects off the host attributes `mod aowl.fovfix 4.386 ms x92 peak 4.263 ms`
  ## -- essentially ALL of it that one arm firing (the other 91 onUpdate ticks summed
  ## ~0.12 ms). Gating the arm on a real effect drops that peak to nothing.
  cfgEnableFovWrite or cfgEnableFovScaleFix or cfgChangeMouseSensitivity

var gArmAsked = false   ## the one-shot that replaced `world.ready()`; see onUpdate

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
  # The whole arm is gated on there being something to arm. `world.ready()` is a
  # one-shot (true on exactly the first tick the type resolves), so this branch runs
  # at most once per run -- but it is where the ~4.3 ms `onWorldReady` cost lives, and
  # paying it to arm four effects that are all switched off is the top FPS cost this
  # mod ever showed in a live raid, for no visible effect. With every effect off the
  # mod stays fully inert: nothing is resolved, nothing is verified, nothing is
  # patched, and the per-frame cost is a single one-shot boolean read.
  # `world.ready()` is a one-shot -- it returns true on exactly the first tick the
  # type resolves and false forever after -- so it MUST be read once per frame, into
  # a local, or a second read consumes the edge and the arm never happens.
  # ARM ON THE FIRST TICK, not on `world.ready()`. MEASURED 2026-09-06 (three
  # DEPLOYED raids on host 5a3fcd01690f): `whenReady("EFT.GameWorld")` never
  # fired, because the host's by-name resolve answers "no such type" for
  # every mod until one is switched to the gated il2cpp layer (host log:
  # "nothing resolves by name through it: no mod has been switched over";
  # sain's arming step 1/7 "answered no" in the same boot). So this mod
  # printed nothing past "loaded", never armed, and the camera stayed at
  # the game's own 60.0 on ADS with enableFovWrite on -- the same 60.0 the
  # control raid with the write OFF measured. The banner above already
  # records that the world gate tested the wrong thing; the arming needs
  # only the runtime and the main-thread drain, which the deferred poll
  # below waits for. One-shot, like `ready()` was.
  let worldReady = not gArmAsked
  if worldReady: gArmAsked = true
  if worldReady and not anyFovEffectEnabled():
    if not gInertSaid:
      gInertSaid = true
      gFovState = "inert: enableFovWrite, enableFovScaleFix and " &
                  "changeMouseSensitivity are all off, so nothing was armed " &
                  "(no runtime bind, no RVA verify, no patch). Turn one on to arm."
      gScaleState = gFovState
      gSensState = gFovState
      gAimSensState = gFovState
      gDriverState = gFovState
      info "FOV: all effects are disabled; not arming. This mod is inert this " &
           "run and costs ~0 -- the ~4.3 ms one-time arm is skipped. Enable " &
           "enableFovWrite / enableFovScaleFix / changeMouseSensitivity to arm."
  elif worldReady:
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
