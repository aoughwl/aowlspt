# FOV Fix, rewritten in nimony for post-1.0 Tarkov

Fontaine's *Fontaine-FOVFix* (`com.fontaine.fovfix`) — a BepInEx plugin with a
per-frame `FovController` component and a handful of Harmony prefixes — reaching
the game through `aowlspt`'s C ABI instead. CC BY-NC-SA 3.0, see `LICENSE.txt`
beside this file; this is a modified redistribution and the copyright holder is
unchanged.

Four effects are implemented. Eight settings groups are read, printed and
**not** applied, and section 3 says which named thing each one is waiting on.
(The count used to read six and never matched the eight groups section 5
enumerates.)

**Nothing here has ever run against BSG's client.** Every `EFT.` name below is
from the pre-1.0 C# surface, and post-1.0 is a different build.
`aowl run mods/fov` prints the whole binding report offline against whatever
`selfTestRuntime` points at, and `verifyHooks` prints the live one a minute into
a raid. Read one of those before drawing any conclusion about what happened in a
raid.

---

## 1. What it changes, and what it does not

| Upstream patch | Here |
|---|---|
| `FovController.Update` — the per-frame FOV write | **ported** — `GameWorld.Instance` → `MainPlayer` → `ProceduralWeaponAnimation` → `IsAiming`, and `CameraManager.Instance` → `SetFov`, entirely on the fast path, rate-limited to ~250 Hz |
| `CalculateScaleValueByFovPatch` | **ported** — `hookArgs` + `stopWith`, returning `fovScale`. Gated on `enableFovScaleFix` |
| `ScopeSensitivityPatch` | **ported** — the magnification→sensitivity table, applied to the optic camera's live field of view |
| `AimingSensitivityPatch` | **ported** — a postfix that scales the getter's own result. Typed (~44 ns) on a revision-4 host, JSON (~1.6 us) on revision 3 |
| `LerpCameraPatch` | **not ported** — a *name* problem, see section 3 |
| `FreeLookPatch` on `Player::Look` | **not ported** — the angles arrive as a `Vector2` placeholder. The method is still detoured, as the first of two per-frame drivers |
| `FovRangePatch` — the base-FOV slider bounds | **not ported** — a *name* problem, see section 3 |
| The toggle-zoom key | **not ported** — needs a `KeyCode` ordinal this port will not guess |

The base FOV is captured once, on the first frame, and never re-read. Reading it
every frame would be a feedback loop, because this mod's own output *is* the
camera's field of view. The cost is that moving the in-game FOV slider mid-raid
does not take effect until the next one, which is stated rather than hidden.

---

## 2. What changed in this pass, and why each change was necessary

Five changes landed under this mod while it sat untouched -- two of them in the
library, one in the host and two in this file. This used to say "four library
changes" and the five subsections below outgrew it.

### `classifyType` stopped answering `fkPtr` for everything

It used to return `fkPtr` for every non-primitive the resolver could find, so
`argsUsable`'s `classifyType(...) == fkNone` test was false for every real EFT
type and **its body had never executed once**. It is a live test now, and a live
test has to agree with what it predicts.

What it predicts is the host's `shapeOfType`: a value type of 1..8 *payload*
bytes arrives as a number, anything else arrives as `{"valueType":"..."}`. The
payload is the reported instance size minus the box header, and the header is
**measured** (`boxHeaderBytes`) rather than assumed. This tested
`classInstanceSize > 24`, which is the same predicate only on a runtime whose
header happens to be 16 — the exact assumption `boxHeaderBytes` exists to
prevent. On `tests/mockil2cpp`, which reports payload sizes, the old test called
a 12-byte `Vector3` readable.

That matters here more than anywhere. `UnityEngine.Vector2` being an unreadable
placeholder is the entire stated reason `Player::Look` is not ported. If the gate
cannot refuse a 12-byte value type, that refusal was a coincidence rather than a
mechanism, and the self-test now watches it refuse one.

### Stated register classes are now checked against the runtime

Every call in the FOV chain is bound with `bindOnObject`, which cannot infer a
signature — it has a class rather than a name. `fast.nim` says in as many words
that "the mod is asserting the register classes, and it is on the mod to be
right". An assertion nobody checks is a remembered signature.

`statedKindsDisagree` compares what the mod asserted against the `MethodInfo` the
bind landed on, once per class rather than per call, using the `Binding.info`
already in hand. The failure it catches is exactly the one the library fixed
centrally this pass: a `System.Double` asserted as `fkF32` reads the wrong half
of XMM0 and answers a plausible field of view. `get_fieldOfView`,
`get_IsAiming`, `get_IsOptic` and `SetFov`'s three parameters are all asserted,
so all six are now checked.

The three `get_Instance` bindings are the only ones in this file whose signatures
are *inferred*, and they were never at risk from the library's float/bool
inference bug: all three return references, which were classified correctly under
both the old rule and the new one.

### `verifyHooks` no longer switches the mod off

The per-frame FOV write rode on the `EFT.Player::Look` detour, that detour was
installed only when `verifyHooks` was true, and setting `verifyHooks` to false in
`config.json` therefore disabled the mod. It logged a warning about it, which is
better than silence and is not a defence. The driver is armed on its own account
now; `verifyHooks` decides only what is counted.

### There is a second driver, and this file used to say it was impossible

`FrameDriver`'s comment read: "the alternative — `onUpdate` — runs on the host's
own attached thread, and `invoke_main` queues onto that same thread rather than
Unity's. Writing a camera's field of view from there is not legal." The first
half is still true. The second half stopped being true when the IL2CPP host
started detouring a per-frame game method of its own and draining `invoke_main`
from inside it — so on a host where that drain bound, `invoke_main` **is**
Unity's thread, and `everyMain` is a once-per-drain callback on it holding one
scheduler slot.

It is not always. Where no candidate could be detoured the queue falls back to
the host's own thread and the old sentence applies in full. So the fallback is
gated on `call("aowlspt.host::main_thread")` reporting `bound`, which the host
sets only once its drain has actually *fired* — the "installed is not reached"
distinction the rest of this mod is built around. Not bound is a refusal, not a
fallback. The firing thread is recorded and printed next to the host's own
answer, so the two can disagree in public.

`everyMain` is also strictly the better shape when it is available: `Look` fires
once per *player* per frame, every bot's included, which is what the ~250 Hz rate
gate exists to compensate for. `everyMain` fires once per frame. The rate gate
stays on both paths — on `everyMain` it will almost never trip, and one
`perfCounter` a frame is cheaper than a second code path.

### The self-test's refusal list had expired

`aowl run` was printing that `get_AimingSensitivity` was not ported "because
every patch this host installs is a prefix detour", for an effect that is a
postfix a hundred lines further up the same file. `LerpCamera` and `Look` were
still quoting the handle-to-pointer cost that ABI revision 3 removed. A stale
refusal is worse than no refusal — it is the file disagreeing with itself in the
one place a reader goes to find out what is missing.

---

## 3. Every refusal that remains, per symbol

Each row is one game symbol this mod needs. "Absent" and "wrong signature" are
the same row because the mod treats them the same way: the runtime is asked, the
answer is printed with the signature it reported, and the effect does nothing.
Nothing here degrades into a guess.

| Refusal | Consequence |
|---|---|
| `EFT.GameWorld::get_Instance` — static, **inferred** | The per-frame FOV write refuses at arm time and the driver refuses with it. The three replacing/scaling hooks are unaffected — none of them touches the world. |
| `EFT.CameraControl.CameraManager::get_Instance` — static, **inferred** | Same: the FOV write only. Both statics are attempted before either is judged, so the report carries a `why` for each rather than leaving the second one zeroed and reasonless. |
| `GameWorld::get_MainPlayer` | The FOV write refuses on the first frame a world exists, with the concrete world class named. Bound against the object, so SPT's raid `GameWorld` subclass is what answers. |
| `Player::get_ProceduralWeaponAnimation` | The FOV write refuses. Bound against the live `LocalPlayer`, so an override is what runs rather than `EFT.Player`'s body. |
| `CameraManager::get_Camera` and `UnityEngine.Camera::get_fieldOfView` | The FOV write refuses. `get_fieldOfView` is asserted as returning a float and that assertion is now checked — a build where it returns a `Double` refuses rather than reading the wrong half of XMM0 and setting the camera from it. |
| `CameraManager::SetFov` — must be `(Single, Single, Boolean)` or `(Single)` | The FOV write refuses, with the signature the runtime reported printed. This port will not guess what a third shape's extra parameters mean. The arity is settled by name at arm time; the binding is taken against the camera manager object, because a subclass may override it. |
| `ProceduralWeaponAnimation::get_IsAiming` | The FOV write refuses. Without it there is no aiming state, and writing the base FOV unconditionally would be a mod that does nothing while claiming to work. |
| `ProceduralWeaponAnimation::get_CurrentScope`, and `get_IsOptic` on whatever it returns | **Not a veto.** Every aim is treated as unmagnified, so `nonOpticFovMulti` applies where `opticFovMulti` would have. A reduced effect rather than a wrong one — but it is recorded and reported. `get_IsOptic` has no name to probe offline: it lives on the class the scope object turns out to be, which is not `CurrentScope`'s declared type. |
| `EFT.Player::Look` — the driver | The write falls back to `everyMain`, and **only** if the host confirms its drain is on Unity's thread. If it does not, the effect is refused with the host's own report quoted. Nothing is written to a camera from the wrong thread. |
| `Player::CalculateScaleValueByFov` — must return `System.Single` | That effect refuses; the viewmodel is rescaled as the game rescales it. Also refused when any parameter arrives as a placeholder, even though this handler reads no argument — a hook whose payload cannot be fully accounted for is the conservative side, and the reason is printed. |
| `SightComponent::get_GetCurrentSensitivity` — must return `System.Single` | Scope sensitivity is the game's. |
| `OpticCameraManagerContainer::get_Instance` **or** `OpticCameraManager::get_Instance`, and `get_Camera` on the container | The scope-sensitivity effect refuses **whole**, before the hook is installed. The table would otherwise be answering from a field of view of zero, which reads as "unmagnified" and is a plausible number rather than a refusal. Both spellings are tried because the container was renamed more than once, and the one that resolved is reported. |
| `FirearmController::get_AimingSensitivity` — must be `() -> System.Single` | Aim sensitivity is unscaled, which is the game's own behaviour. A non-zero parameter count is refused with "the name is probably stale on this build", because a property getter takes none. |
| A host older than ABI revision 4 (`typedPatchesReady`) | The aiming-sensitivity postfix arms on the JSON path at ~1.6 us a call instead of ~44 ns. Not a refusal — this getter is asked once per aiming frame for one player — and the state line says which armed, because the two are thirty-six-fold apart and "armed" alone would hide that. |
| The typed frame's `setResultFloat` refuses at runtime | The handler returns `frameContinue()` rather than `frameReplace()`, so the caller gets the original's unscaled sensitivity. Saying `frameReplace()` anyway would hand back whatever residue is in the register, which is the difference between a failure and a wrong number. |
| The host does not answer `aowlspt.host::main_thread` | Only matters when `Look` could not be detoured. In that case the `everyMain` fallback refuses, because there is no thread it could be *shown* to reach. |
| `ProceduralWeaponAnimation::LerpCamera` — **not attempted** | The ADS camera lerp is the game's. Every capability blocker this file used to name is gone: `this` is delivered, an address for it costs ~8 ns, and `bindRaw`/`ShapedArgs` binds a method by its native slot shape, which is exactly what Win64 does with a 12-byte `Vector3`. What is left is that this port cannot confirm the camera-offset field names on `ProceduralWeaponAnimation` against a running build, and will not write a camera offset through a guessed name. All three distance offsets (`opticCameraDistanceOffset`, `nonOpticCameraDistanceOffset`, `pistolCameraDistanceOffset`), the shoulder offsets, the six per-axis camera offsets and the camera and aim/un-aim speeds are all read, printed and inert because of this one row. The list here used to name only the optic one. |
| `Player::Look`'s angles — **not attempted** | Free-look is unclamped. This one is about the payload rather than the instance: the angles arrive as a `UnityEngine.Vector2`, which is passed by hidden pointer and reported as `{"valueType":"..."}` — named and refused rather than invented — so there is nothing in the payload to clamp. A postfix does not help; `Look` returns void. |
| `GameSettingsTab`'s slider-bounds field — **not attempted** | `minBaseFov`/`maxBaseFov` are read, and when they are the wrong way round they are **replaced with upstream's 50..75** rather than exchanged -- this row used to say "swapped ... exactly as upstream swaps them", and `loadConfig` discards both hand-edited values instead. Either way they are never applied. The instance is delivered and this fires when a menu opens, so the cost objection does not apply; what cannot be confirmed from here is which field holds the bounds. |
| `UnityEngine.Input::GetKey` — **not attempted** | `zoomToggleKey`, `holdToZoom`, `cancelZoomOnUnAds`, `zoomOnHoldBreath` and the six `*ToggleZoom*Multi` settings are read, printed and inert. Half of this objection expired: an enum argument is a plain number to the host now, so `GetKey` is callable the moment this mod has a number to pass it. The other half stands — this mod has the string `"M"` out of `config.json`, and turning one into a `KeyCode` ordinal means writing Unity's enumeration out from memory. That is a guess about a value, and it is the same class of refusal as the camera-offset field names. |
| `ScopeZoomHandler`, `GameSettingsTab` as *types* | Reported as `NOT FOUND` in the world-ready log and nothing else. They exist only as the cheapest confirmation that a rename would show up somewhere legible before it shows up as a different bug. |

---

#### What a raid would be the first to disprove

In descending order of how likely a raid is to embarrass it.

1. **`SetFov` is not the write that decides the field of view.** The whole
   per-frame effect is one call, its shape is confirmed against the runtime, and
   nothing confirms that the game does not overwrite it later in the same frame
   from its own controller. The symptom is a write count that rises steadily and
   a field of view that never moves, and the report already flags "armed but
   never applied" — it would not flag "applied and immediately undone".
2. **The base FOV is captured from a frame where it is already wrong.** It is
   read once, on the first frame the whole chain resolves, and if that frame
   catches the camera mid-transition every subsequent write is a multiple of the
   wrong number. Nothing here can tell a settled camera from a transitioning one.
3. **`everyMain` is on the wrong thread anyway.** The fallback trusts the host's
   `bound` flag, which the host sets when its drain has fired on a thread that is
   not its own. Strong evidence, not proof that the thread is Unity's player loop
   rather than some other engine thread the drain method happens to run on. The
   mod records its own firing thread and prints it next to the host's number;
   nobody has compared them on BSG's client.
4. **The optic camera is not the sight being asked for sensitivity.** The
   scope-sensitivity hook is not told which `SightComponent` fired it, and it
   answers from the optic camera's live field of view on the assumption that in a
   raid there is one sight being aimed through. A build that queries sensitivity
   for a sight the player is not looking through gets the wrong multiplier, and
   there is no way to tell that from here.
5. **The ~250 Hz rate gate is the wrong rate.** It exists because `Look` fires
   once per player per frame including bots, and it assumes the write is
   idempotent and that skipping one is invisible. At very high frame rates with
   very fast ADS transitions, a 4 ms gate is a visible step rather than a smooth
   ramp. On the `everyMain` path the gate is nearly inert and this concern
   disappears — which means the two drivers can feel different.
6. **`get_IsOptic` lives somewhere else on this build.** Optic detection is
   deliberately not a veto, so its failure is silent in the sense that the mod
   keeps working — every magnified aim just gets the unmagnified multiplier. The
   count in the report does not separate "no optic" from "could not tell".
7. **The magnification→sensitivity thresholds are pre-1.0 numbers.** The table
   maps a field of view in degrees onto a magnification bracket, and those
   degree boundaries are upstream's. The self-test proves the table is monotonic;
   it cannot prove the brackets line up with any actual scope.
8. **`CalculateScaleValueByFov` does more than scale.** Replacing its body with a
   constant is upstream's patch, and it assumes the method's only effect is its
   return value. A post-1.0 body with a side effect would lose it silently.

---

## 4. Reading the log

`aowl run mods/fov` runs the whole self-test with no game attached. It checks the
one thing that needs no runtime at all — the magnification→sensitivity table's
monotonicity, because a config with two multipliers the wrong way round produces
a scope that gets twitchier as it zooms in, which is the exact bug the table
exists to remove.

With a runtime to bind against — `aowl run` and `aowl test` set
`AOWLSPT_SELFTEST_RUNTIME` to the stand-in `tests/mockil2cpp/GameAssembly.dll`
they build — the binding half becomes a real answer offline and the guard block
is exercised rather than described. (`selfTestRuntime` in `config.json` does the
same for a runtime of your own, and takes an **absolute** path only: it ships
into installs, and a relative path there would name whatever the game's own
working directory happened to hold.)

```
info    the guards, exercised rather than described:
ok      guard ok argsUsable refuses a UnityEngine.Vector3 parameter -- argument 0
        (UnityEngine.Vector3) is a 12-byte value type, so it arrives by hidden
        pointer and the host reports {"valueType":"UnityEngine.Vector3"}
ok      guard ok argsUsable accepts (System.Single, System.Boolean)
ok      guard ok ensureCall accepts get_MainPlayer stated as returning a reference
ok      guard ok ensureCall refuses get_MainPlayer stated as returning a float
```

The first is the mechanism behind the `Player::Look` refusal, watched refusing a
value type of the same shape. The last is the mistake `bindOnObject` cannot catch
on its own: an address read out of XMM0, which holds whatever the last
floating-point operation left there — a number, not a crash. With no
`selfTestRuntime` the block prints "not checked" instead of passing, which is
deliberate: a check that passes because the thing it checks never happened is
worse than no check.

In a raid, the world-ready block prints one line per effect and one for the
driver, and a minute in, `verifyHooks` prints what fired and what applied. Those
are different claims, and an effect that armed and never applied is the
interesting failure, so it is reported as one rather than left to be inferred
from a fire count.

---

## 5. Config

`config.json` is flat, because the client host reads it as flat keys; BepInEx's
sections survive as the grouping of the variables and the ordering in the file.

Applied: `opticFovMulti`, `nonOpticFovMulti`, `changeMouseSensitivity` and the
eleven `*SensMulti` values, `enableFovScaleFix` and `fovScale`.

Read, printed and inert, each with its row in section 3: the six camera offsets
and three distance offsets, the two shoulder offsets, the two offset keys, the
toggle-zoom group, the three camera speeds, the nine aim/un-aim speeds, and
`minBaseFov`/`maxBaseFov`.

Three are aowlspt's rather than upstream's: `verifyHooks`, which now decides
only whether the target-verification detours are attached, and `selfTestRuntime`
and `selfTestDataDir`, both read on the sim side only. `selfTestDataDir` was
missing from this list.
