# Classic Movement, rewritten in nimony for post-1.0 Tarkov

TheBoogle's *Old Tarkov Movement (no inertia)* — `com.boogle.oldtarkovmovement`,
two BepInEx/Harmony projects and about six patches — reaching the game through
`aowlspt`'s C ABI instead. MIT, see `LICENSE.txt` beside this file; this is a
modified redistribution and the copyright holder is unchanged.

Client and server halves are one binary here, split by `side()`. The server half
is a complete port. The client half is partial and section 1 says which parts,
by name, with the reason each one is out.

**Nothing here has ever run against BSG's client.** Every `EFT.` name below is
from the pre-1.0 C# surface plus the SPT 4.1.2 rename map, and post-1.0 is a
different build. `aowl run mods/classicmovement` prints the whole binding report
offline against whatever `selfTestRuntime` points at, and `verifyHooks` prints
the live one a minute into a raid. Read one of those before drawing any
conclusion about what happened in a raid.

---

## 1. What it changes, and what it does not

One write, on the client, plus four more effects that suppress rather than
write. This used to read "three writes ... plus two more", which the table
below never supported: there is one `writeFloat` and four `stopVoid`s.

| Upstream patch | Here |
|---|---|
| `SmoothSpeedFix` on `MovementContext::ManualUpdate` | **ported** — `_player` and `SmoothedCharacterMovementSpeed` are bound by offset against the live context's own class, and the speed is written every frame on the fast path |
| `BushSpeedStateRemover` on `::OnEnterObstacle` | **ported** — `hookArgs` reads the obstacle argument, `stopVoid` suppresses the original when it carries the swamp speed limit |
| `AimingSlowdownPatch` on `::SetAimingSlowdown` | **ported** — `hookArgs` + `stopVoid`, gated on `DoesAimingSlowYouDown` exactly as upstream gates it |
| `OldTiltingFix` on `::InertiaSmoothTilt` | **ported** — the redirect into `LegacySmoothTilt` is a bound non-virtual call on the context the hook fired for. Typed hook (~25 ns) on a revision-4 host, JSON (~2.2 us) on revision 3 |
| `RemoveJitteryRotationPatch` on `::PlayerAnimatorSetDeltaRotation` | **half ported** — the player/AI split is done; upstream's `TRANSFORM_ROTATION_LERP_SPEED` constant is not, because this port cannot confirm it against a running build |
| `StateReplacer` on `::GetNewState` | **not ported, permanently** — its replacement states are C# subclasses, and nothing native can declare a managed type |
| The Fika patches | out — the Fika assembly does not exist on this side of 1.0 |
| Nostalgia Mode | out — upstream stopped supporting it. Still read and still served on the wire, so a client written against the original protocol still deserialises |

Nothing else is written. The server half serves one route,
`/OldTarkovMovement/GetConfig`, bare and unenveloped, exactly as upstream does.

---

## 2. What changed in this pass, and why each change was necessary

Six changes landed under this mod while it sat untouched: two library changes,
three fixes in this file, and one host change that made a second driver
possible. One of the library changes altered a guard from decorative to real.
This used to say "four library changes"; the six subsections below outgrew it.

### `classifyType` stopped answering `fkPtr` for everything

It used to return `fkPtr` for every non-primitive the resolver could find. Two
gates in this file test `classifyType(...) == fkNone`, and **neither could
fail** — the test was false for every real EFT type, so the body behind it had
never executed once.

* **`argsUsable`** is now a live test, and a live test has to agree with the
  thing it predicts. That thing is the host's `shapeOfType`: a value type of
  1..8 *payload* bytes arrives as a number, anything else arrives as
  `{"valueType":"..."}`. The payload is the reported instance size minus the box
  header, and the header is **measured** (`boxHeaderBytes`) rather than assumed.
  This tested `classInstanceSize > 24`, which is the same predicate only on a
  runtime whose header happens to be 16 — the exact assumption `boxHeaderBytes`
  exists to prevent. On `tests/mockil2cpp`, which reports payload sizes, the old
  test called a 12-byte `Vector3` readable.
* **`bindFieldOn`** refuses a field it cannot classify. That refusal was
  unreachable, so a `Vector3` field would have bound as a reference and
  `readFloat` on it would have answered a number.

### `bindFieldOn` decided staticness from an offset, which cannot decide it

`fast.bindField` asks `il2cpp_field_get_flags` first and says why: a static
field's offset is into the class's static data block, and the two ranges overlap
completely. `tests/mockil2cpp` has `EFT.Player::SpawnCount` (static, `Int32`) at
offset 16 and `EFT.Player::Health` (instance, `Single`) at offset 16, which is
ordinary rather than contrived — neither number knows about the other.

This mod's own `bindFieldOn` had only the offset test, so it would have bound
`SpawnCount` as an instance field with `ok` true and read `Health`'s bits as an
integer: `1120403456`, with total confidence. It asks the runtime now, and
refuses outright on a runtime that does not export the flag rather than falling
back on a test that cannot answer the question. It also classifies from the
**declared type** first and the printed name second, matching `bindField`.

### Stated register classes are now checked against the runtime

Every call in this mod's chains is bound with `bindOnObject`, which cannot infer
a signature — it has a class rather than a name. `fast.nim` says in as many words
that "the mod is asserting the register classes, and it is on the mod to be
right". An assertion nobody checks is a remembered signature.

`statedKindsDisagree` compares what the mod asserted against the `MethodInfo` the
bind landed on. It costs one walk of the parameter list per class, not per call,
because `Binding.info` is already in hand. This is the same class of bug the
library fixed centrally this pass — `bindMethod` used to classify `System.Single`
by width and pass it in a general-purpose register — and stating the kinds is
precisely how this mod opted out of that fix in both directions.

### `verifyHooks` no longer switches the mod off

`SmoothSpeedFix` rode on the `ManualUpdate` detour, that detour was installed
only when `verifyHooks` was true, and setting `verifyHooks` to false in
`config.json` therefore disabled the effect the mod exists for. It logged a
warning about it, which is better than silence and is not a defence.

The driver is armed on its own account now. `verifyHooks` decides only what is
*counted*.

### There is a second driver, and it exists because the host changed

`everyMain` runs a callback on the host's main-thread queue once per drain,
re-arming itself from inside its own firing and holding one scheduler slot. What
makes it usable here is a separate fact: the IL2CPP host now detours a per-frame
game method of its own and drains `invoke_main` from inside it, so on a host
where that drain bound, `invoke_main` **is** Unity's thread.

It is not always. Where no candidate could be detoured the queue falls back to
the host's own thread, and a movement write from there is a crash a frame or two
later, far from the write. So the fallback is gated on
`call("aowlspt.host::main_thread")` reporting `bound`, which the host sets only
once the drain has actually *fired* — the same "installed is not reached"
distinction the rest of this mod is built around. Not bound is a refusal, not a
fallback. The firing thread is recorded and printed next to the host's own
answer, so the two can disagree in public.

### The self-test's refusal list had expired

`aowl run` was printing that `InertiaSmoothTilt` and
`PlayerAnimatorSetDeltaRotation` were blocked on the cost of turning a host
`Handle` into a pointer. That has been false since ABI revision 3, and the module
comment had said so for a while; the self-test block was never updated with it. A
stale refusal is worse than no refusal — it is the file disagreeing with itself
in the one place a reader goes to find out what is missing.

---

## 3. Every refusal that remains, per symbol

Each row is one game symbol this mod needs. "Absent" and "wrong signature" are
the same row because the mod treats them the same way: the runtime is asked, the
answer is printed with the signature it reported, and the effect does nothing.
Nothing here degrades into a guess.

| Refusal | Consequence |
|---|---|
| `EFT.GameWorld::get_Instance` — static, the only binding in this file whose signature is **inferred** | `SmoothSpeedFix` refuses at arm time and the driver refuses with it, naming the type. Every other effect is unaffected — the bush, aiming, tilt and jitter patches never touch the world. This is the one binding the library's `bindMethod` float/bool inference bug could have reached, and it could not: the return is a reference, which was classified correctly under both the old rule and the new one. |
| `GameWorld::get_MainPlayer` | `SmoothSpeedFix` refuses on the first frame a world exists, with the concrete world class named. Bound against the object, so SPT's raid `GameWorld` subclass is what answers, not `EFT.GameWorld`'s body. |
| `Player::get_MovementContext` | Same: `SmoothSpeedFix` only. Bound against the live `LocalPlayer`, so an override is what runs. |
| `MovementContext::_player` — private instance field | `SmoothSpeedFix` refuses. This read exists to *prove* the context found by walking the world is the context this player drives; without it the write would be to a context nobody has established anything about, so it is a refusal rather than a skipped check. |
| `MovementContext::SmoothedCharacterMovementSpeed` — instance field, must be `Single` or `Double` | `SmoothSpeedFix` refuses, and separately refuses if the field resolves but is not a float — that check is explicit, because a field of the right name and the wrong type is the failure that writes a float's bits into an integer. |
| `Player::ClampedSpeed` (field) **or** `Player::get_ClampedSpeed` (property) | Tried in that order, because the field read is 1.9 ns against 8.4. If neither answers, `SmoothSpeedFix` refuses and names both attempts. Which one was used is in the state line. |
| `MovementContext::ManualUpdate` — the driver | The write falls back to `everyMain`, and **only** if the host confirms its drain is on Unity's thread. If it does not, the effect is refused with the host's own report quoted. Nothing is written from the wrong thread. |
| `MovementContext::OnEnterObstacle` — must be `(x) -> void` | `BushSpeedStateRemover` refuses. A non-void return is refused by name, because suppressing a method that returns something means inventing the something. An arity other than one is refused, because this reads the obstacle out of a single argument by index. Bushes slow you down, which is the game's own behaviour. |
| The obstacle's `HasSwampSpeedLimit` — read as a property, then as a field | Neither answering means `limited` is false and the original runs, so a bush behaves as the game intends. The count of obstacles seen versus obstacles suppressed is in the report, so "the name is wrong" and "no swamp bushes on this map" can be told apart. |
| `MovementContext::SetAimingSlowdown` — must return void | `AimingSlowdownPatch` refuses; aiming slows you down. Also refused when any parameter arrives as a placeholder, even though this handler reads no argument — a hook whose payload cannot be fully accounted for is the conservative side to be on, and the reason is printed. |
| `MovementContext::InertiaSmoothTilt` — must be `(Single, Single) -> void` | `OldTiltingFix` refuses and leaning keeps its inertia ramp. The signature is checked before the hook is installed, not after. |
| `MovementContext::LegacySmoothTilt` — the redirect target, same signature | **Checked before the original is suppressed.** Suppressing `InertiaSmoothTilt` and then failing to reach `LegacySmoothTilt` is a frozen lean, and it would only show up in a raid. If the target is missing or shaped differently, the effect refuses whole and the original lean runs. |
| A host older than ABI revision 3 (`livePointersReady`) | **No longer a refusal — both effects arm on a handle-only path.** This row used to say both refuse, on the arithmetic that a ~1 us boxed call per movement context per frame is "2.4 ms a frame" at forty bots. 2.4 ms is what that costs in a *second*; in a frame it is 40 us, **0.240%** of 16.67 ms, and the percentage was wrong twice over because a second's total was divided by a frame's budget. Measured properly (docs/PERF.md: 626.5 ns of JSON hook dispatch plus 951.5 for a boxed call with the class in hand) the redirect is 1.6 us a firing, 64 us a frame, **0.384%**; the boxed `IsAI` read is 1112 ns a firing, 44 us a frame, **0.267%**. None of that is a reason to refuse a feature, so the refusals are withdrawn and `onInertiaSmoothTiltBoxed` / `onDeltaRotationBoxed` run instead. Both suppress the original **only after** the boxed replacement has come back `ok`, because a suppression that failed to reach its replacement is a frozen lean or every bot's rotation suppressed. Neither has ever run: every host in this tree is revision 4, so this is an argument from code. |
| A host older than ABI revision 4 (`typedPatchesReady`) | `OldTiltingFix` arms on the JSON path instead, at ~2.2 us a *firing* — 88 us a frame at forty contexts, 0.528%. Not a refusal, and this row used to justify that with "four or five contexts in a solo raid", as though forty would have been disqualifying; at forty it is half of one percent. The state line says which path armed, because the two are a hundredfold apart and that is worth knowing even when both are affordable. The 2.2 us is an unmeasured ceiling: PERF.md's parts add to about 700 ns, and the pessimistic figure is kept because a decision taken on it stays right. |
| `MovementContext::PlayerAnimatorSetDeltaRotation` — must return void | `RemoveJitteryRotationPatch` refuses; rotation is written as the game writes it. |
| `MovementContext::get_IsAI` (property) **or** `IsAI` (field) | Neither answering means the original runs for **everything**, bots included. Suppressing for everything is not what upstream does and would be a guess about which contexts matter, so the effect declines to act rather than acting broadly. Which of the two answered **is** reported now, in the effect's report line. Two rows ago this claimed the log said which; one row ago it admitted it did not, because `contextIsAi` took a `known: var bool` and set it true down either branch. It takes a `how: var string` now, names the branch it returned from, and the self-test asserts the string against a runtime that has `get_IsAI` as a property and one that has neither. The **field** branch is still unexercised: no type in `tests/mockil2cpp` carries `IsAI` as a field, and inventing one to test against would be testing the invention. |
| `EFTHardSettings::TRANSFORM_ROTATION_LERP_SPEED` | **Not attempted at all.** This is the only refusal in the file about a *value* rather than a symbol: upstream writes a constant this port cannot confirm against a running build, and inventing a lerp speed is the approximation everything else here refuses. Half of `RemoveJitteryRotationPatch` is therefore permanently out until somebody measures the number. |
| `MovementContext::GetNewState` | **Permanent, and not the kind an ABI fixes.** The replacement states are C# subclasses with `UpdatePosition` overridden; nothing native can declare a managed type, construct one, or hand it back as a reference return. Watched and counted so the log can at least say the method is live. Its second, older blocker — that an `EPlayerState` argument would be handed to the collector as an object — is gone: the host asks the runtime and an enum arrives as its number. |
| A runtime with no `il2cpp_field_get_flags` | Every field this mod binds against a live object is refused, so `SmoothSpeedFix` does not arm. There is no way to establish that a field is an instance field on such a runtime, and an offset cannot stand in for the flag. Refusing beats a read that answers a neighbouring field. |
| The host does not answer `aowlspt.host::main_thread` | Only matters when `ManualUpdate` could not be detoured. In that case the `everyMain` fallback refuses, because there is no thread it could be *shown* to reach. |
| Any of the nine `gameType` names (`EFT.MovementContext`, the six movement states, `EFTHardSettings`, `ProceduralWeaponAnimation`) | Reported as `NOT FOUND` in the world-ready log and nothing else. These are not used for anything but the cheapest possible confirmation that the 4.1.2 rename map still matches the build that is running, so a miss is a diagnostic rather than a failure. |

---

#### What a raid would be the first to disprove

In descending order of how likely a raid is to embarrass it.

1. **The driver is armed and the write never lands.** `SmoothSpeedFix` is the
   whole point of the mod and every one of the six symbols in its chain is a
   pre-1.0 name. The chain refuses loudly at each step, so the failure is
   legible — but "legible" is not "unlikely", and this is the newest arrangement
   in the file because the driver was pulled out of the `verifyHooks` block this
   pass. The symptom is `armed` in the state line with a write count of zero,
   which the report already calls out as the interesting failure.
2. **`everyMain` is on the wrong thread anyway.** The fallback trusts the host's
   `bound` flag, and the host sets it when its drain has fired on a thread that
   is not its own. That is strong evidence and it is not proof that the thread is
   Unity's player loop rather than some other engine thread the drain method
   happens to run on. The mod records its own firing thread and prints it next to
   the host's number so the two can be compared; nobody has compared them on
   BSG's client.
3. **`InertiaSmoothTilt` and `LegacySmoothTilt` are not the pair they were in
   4.1.2.** Both resolving and both patching is what this port has, and the
   evidence that they are the 4.1.2 names of the obfuscated `method_15`/
   `method_14` pair is that the first fires while leaning — on 4.1.2, not on
   post-1.0. If the redirect target is a different method with the same shape,
   the suppression succeeds and the lean is wrong in a way no counter shows.
4. **`ClampedSpeed` is the wrong number on this build.** The mod checks that it
   is a float and that it is reachable; it cannot check that it is still the
   clamped movement speed rather than something renamed onto the same word. The
   symptom would be a write that lands, a count that rises, and movement that
   feels wrong rather than absent.
5. **`_player` no longer points where it did.** The back-reference is read to
   prove the context belongs to the player, and a build that keeps the name and
   changes the meaning turns that proof into a formality. Nothing here would
   notice.
6. **Suppressing `OnEnterObstacle` outright does more than upstream did.**
   Upstream reads the swamp flag and drops it; this skips the whole method when
   the flag is set, which is the same outcome only if the method does nothing
   else that matters. On post-1.0 it may.
7. **The `everyMain` path fires less often than a frame.** The host's drain is
   once per frame on the method it chose, and this mod does not check
   `perFrame` — it does not need a frame rate, only a legal thread. If the drain
   method turns out to fire less often, the write is less frequent than
   advertised and inertia comes back intermittently.
8. **`verifyHooks` reports zero for something that is live.** A minute is long
   enough for a method reached by leaning or by entering a bush, and it is an
   assumption about how the first minute of a raid is spent.

---

## 4. Reading the log

`aowl run mods/classicmovement` runs the whole self-test with no game attached.
With a runtime to bind against — `aowl run` and `aowl test` set
`AOWLSPT_SELFTEST_RUNTIME` to the stand-in `tests/mockil2cpp/GameAssembly.dll`
they build — the binding half becomes a real answer offline, and the guard block
below it is exercised rather than described. (`selfTestRuntime` in `config.json`
does the same for a runtime of your own, and takes an **absolute** path only: it
ships into installs, and a relative path there would name whatever the game's
own working directory happened to hold.)

```
info    the guards, exercised rather than described:
ok      guard ok argsUsable refuses a UnityEngine.Vector3 parameter -- argument 0
        (UnityEngine.Vector3) is a 12-byte value type, so it arrives by hidden
        pointer and the host reports {"valueType":"UnityEngine.Vector3"}
ok      guard ok argsUsable accepts (System.Single, System.Boolean)
ok      guard ok argsUsable accepts an enum parameter (it arrives as a number)
ok      guard ok bindFieldOn refuses the static SpawnCount
ok      guard ok bindFieldOn binds the instance Health at the same offset
ok      guard ok ensureCall accepts Drift stated as (float, float) -> void
ok      guard ok ensureCall refuses Drift stated as (int32, int32)
```

Those seven are the three guards this pass rewrote, watched refusing against a
real runtime. The pair at offset 16 is the point of the fourth and fifth: the
static field and the instance field are the same offset, and the guard tells them
apart by asking rather than by measuring. With no `selfTestRuntime` the block
prints "not checked" instead of passing, which is deliberate — a check that
passes because the thing it checks never happened is worse than no check.

In a raid, the world-ready block prints one line per effect and one for the
driver, and a minute in, `verifyHooks` prints what fired and what applied. Those
are different claims: a hook that fires and an effect that applies are not the
same thing, and an effect that armed and never applied is the interesting
failure, so it is reported as one rather than left to be inferred.

---

## 5. Config

`config.json` carries upstream's member names, because they are also the member
names on the wire and a client written against the original mod deserialises by
exactly these. `NoInertia`, `QuickTilting`, `DoBushesSlowYouDown`,
`BotsUseOldMovement`, `DoesAimingSlowYouDown`, `RemoveJitteryRotation`,
`NostalgiaMode`.

Three are aowlspt's rather than upstream's: `verifyHooks`, which now decides
only whether the target-verification detours are attached, and `selfTestRuntime`
and `selfTestDataDir`, both read on the sim side only.

`selfTestDataDir` was read by the code and **absent from the file** until today,
which is the worst place for a setting to be: `setting("selfTestDataDir")`
answered "" and the self-test started the runtime without a data directory,
and no reader of `config.json` could have discovered the key existed. It is
declared now, empty, with the `//`-prefixed sibling comment the other keys
carry, and the self-test asserts it is there — `setting(...).ok` tells absent
from empty, so the check cannot be satisfied by the default.

`BotsUseOldMovement` only ever mattered inside the `GetNewState` replacement,
which is not expressible here. It is carried in config and on the wire and does
nothing. Of what this port does apply, the bush and aiming suppressions already
reach every movement context and `SmoothSpeedFix` reaches only the local
player's.
