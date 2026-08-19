# SPT-SWAY, rewritten in nimony for post-1.0 Tarkov

Five independent physical sources of weapon sway — respiration, cardiac,
physiological tremor, postural drift and weapon inertia — summed, scaled by the
shooter's condition and the weapon in their hands, and pushed into BSG's own
rotation springs. `com.savannt.sptsway` 3.2.0, a rewrite of the BepInEx plugin
of the same guid: the physics is ported constant for constant, the C# was only
its previous host.

**Nothing in this mod has ever run against BSG's client.** Everything below is
either arithmetic that was measured offline, or an assumption that is labelled
as one. The self-test that produced every number here is

    installer\build\aowl.exe run mods\sway

which ticks `model/**` with no game in the process — that is the whole reason
`model/` does not import `aowlspt`. Run it from PowerShell; `gcc` fails silently
under Git Bash on this machine.

---

## 1. The raid checklist — read this first

This mod's largest unknowns are not in the physics. They are two facts about
BSG's `Spring` class that cannot be read from outside a raid, and one raid
settles both. **The questions are in dependency order and answering them out of
order will produce a wrong answer to the next one.**

| # | What you see | What it means | What to change |
|---|---|---|---|
| **1** | **Nothing moves at all.** The log says the model is driving the springs and the weapon is stock. | `AddAcceleration` is being fed a number sixty times too small. | `springs.accelerationPerFrame` → `true` |
| **2** | **The weapon is pinned, or snaps between extremes.** It fights the spring rather than riding it. | The same number is sixty times too large and is hitting `AccelerationMax` every frame. | `springs.accelerationPerFrame` → `false` (the shipped default) |
| **3** | **Flick the view and let go.** Does it ring, or lag? | Rings and keeps ringing for **~13.4 s** → `Damping` is a **per-second rate** (ζ = 0.104, underdamped). Sluggish, taking **~24.1 s** to even follow you → it is a **per-frame fraction** (ζ = 9.05, overdamped). | Nothing. This is not a config switch — see §2. It changes what answer 4 is. |
| **4** | **The weapon swims while you stand still.** | The model is too strong for whichever spring you actually have. | `general.masterIntensity` → **0.1886** if answer 3 was *rings* (per-second), **3.733** if it was *sluggish* (per-frame) |
| **5** | Anything else, or before drawing any conclusion at all. | | Read the log's first actuation line. |

**Step 5 is not optional and it invalidates steps 1–4 if it disagrees.** The
first frame this mod actuates, `game/live.nim` prints the spring's *own*
constants:

    sway  spring: ReturnSpeed 7.000, Damping 0.5500, AccelerationMax 12.000
          (all three read off the live spring)
    sway  spring: resonates at 0.4211 Hz, holds at most 1.714 deg, and settles
          in 40.900 s if Damping is a per-frame fraction or 13.433 s if it is a
          per-second rate.

Every number in this file is computed from those three and from nothing else. If
the line says "(all three are this mod's shipped guesses)" the walk to the
spring failed and the calibration is derived from a default; if it reports
different constants, re-run the self-test with them and the checklist's numbers
move with them.

### Why 0.1886 and 3.733, and why they are not guesses

Both come from one binding constraint: **a spent shooter must still be able to
hold a 50 cm chest at 20 m**, whose angular half-width is 0.716 deg. The model
at "spent" produces a weapon deflection of

* **3.796 deg** if the spring is underdamped (per-second `Damping`) — 0.716 / 3.796 = **0.1886**
* **0.1918 deg** if it is overdamped (per-frame `Damping`) — 0.716 / 0.1918 = **3.733**

The looser constraint — a *rested* shooter on a chest at 50 m — gives 0.5053 and
5.538 respectively, and is not the one that binds. The self-test prints both
pairs and names which one binds, so the derivation can be checked rather than
believed.

---

## 2. The two assumptions, and they are worth very different amounts

### 2a. The acceleration form — `springs.accelerationPerFrame`

A Unity spring of this shape is written one of two ways and BSG's source is not
readable from here:

    A. velocity += acceleration          "per frame"   dc gain 8.571 deg/accel
    B. velocity += acceleration * dt     "per second"  dc gain 0.1429 deg/accel

They differ by a factor of **60.000×** at 60 fps, and that factor *is* the whole
calibration. The default is **B**, and the evidence is dimensional rather than
empirical: under B the shipped `AccelerationMax` of 12 admits **1.714 deg** of
weapon rotation, which is the scale weapon sway actually has; under A the same
clamp admits **102.9 deg**, which is a weapon that has left the screen. A clamp
constant is only meaningful at the scale of the thing it clamps.

**That is an argument, not a measurement, and this file will not call it one.**
It is one boolean, both branches are frame-rate independent, and the failure
mode is unmistakable rather than subtle — which is what steps 1 and 2 above
exploit.

### 2b. The damping law — not a switch, and the bigger unknown

`Damping` is a number in 0..1 whose only documented meaning is "higher settles
the weapon faster". Two laws fit that sentence and they are three orders of
magnitude apart:

| | law | effective rate at `Damping` = 0.55 | ζ against ω_n = 2.65 rad/s |
|---|---|---|---|
| per **frame** | `velocity *= (1 - Damping)` each frame | 47.9 /s | **9.054** — grossly overdamped |
| per **second** | `velocity *= exp(-Damping * dt)` | 0.55 /s | **0.1039** — barely damped |

What that does to a unit step:

| | overshoot | rise to 90% | settle to 2% |
|---|---|---|---|
| per frame (overdamped) | −0.018 % | **24.100 s** | 40.900 s |
| per second (underdamped) | **71.97 %** | **0.600 s** | 13.433 s |
| ratio | — | **40.167×** | 3.045× |

Both figures agree with the textbook closed form for a second-order system to
within 1.50× and 0.92× respectively, which is the check `model/spring.nim`'s
`analyticOvershoot` / `analyticSettle` exist to make: if the discrete integrator
and the closed form disagreed, one of the two would be wrong and it is worth
knowing that before a raid rather than during one.

**There is no config key for this**, and there should not be: the spring is
BSG's and the mod does not integrate it. `SpringCal.dampingPerSecond` exists
only so the offline model can report both futures, and `spring.calibration`
hard-codes it to `false`. Knowing the answer changes nothing this mod *writes*;
it changes what `masterIntensity` should be, which is why it is question 3 and
not question 4.

### What the spring does to each source, under each law

Gain in degrees of weapon rotation per degree of model output, measured through
the same `step` the rest of the characterisation uses:

| source | frequency | overdamped | underdamped |
|---|---|---|---|
| respiration, rested (14 bpm) | 0.23 Hz | 0.0894 | 1.350 |
| postural drift | 0.28 Hz | 0.0348 | 1.790 |
| **the spring's own resonance** | **0.4211 Hz** | 0.0492 | **4.556** |
| cardiac | 1.1 Hz | 0.0188 | 0.1758 |
| physiological tremor | 9.5 Hz | 0.0016 | 0.0046 |

The model's whole slow band sits on the spring's resonance. That is the factor
of ~100 between the two columns, and no amount of offline work closes it.

---

## 3. What the model produces, before the spring

Sixty seconds of aiming, at the shipped tuning:

| state | model peak | model rms | weapon, overdamped | weapon, underdamped |
|---|---|---|---|---|
| rested | 0.8985 deg | 0.3537 deg | 0.1035 deg | 1.134 deg |
| spent | 1.872 deg | 0.6981 deg | 0.1918 deg | 3.796 deg |
| full exertion | 6.000 deg (capped) | 5.984 deg | 0.4418 deg | 4.844 deg |

Full exertion would reach **85.234 deg** — 94.868× the rested state — were it
not for `general.maxDeflectionDeg`, and it spends 3588 of 3600 frames against
that ceiling. The stance, fatigue, injury and shot multipliers compose by
multiplication, so the ceiling is a structural necessity rather than a taste
setting.

Frame-rate independence, measured over 30 / 60 / 144 / 240 fps: the *model's*
rms spreads by **0.098 %** with tremor off and **0.039 %** with it on. The
*weapon's* rms does not — 0.0900 deg at 30 fps against 0.1370 at 240 — because
the stand-in spring is a splitting integrator being asked to resolve a damping
rate of 48/s, and that is a property of the stand-in, not of the mod. The
calibration is a steady state with no velocity in it and is untouched by it.

The old `driveGain = 8`, for reference on what was fixed: it delivered 2.286×
the intended degrees at 30 fps, 1.143× at 60, and 0.5714× at 120. It was
frame-rate dependent in exactly the way the comment on that line said it was
not.

---

## 4. What is bound in the game, and what each refusal costs

`game/binding.nim` binds a scalar as a field where the type has one and as a
`get_X`/`set_X` pair where it does not, against the **concrete class of a live
object** rather than a name written down here. Every binding is reported once —
`debug` when it took, `warn` with the reason when it did not — and a refused
binding produces the caller's default, never a wrong number.

| symbol | what it feeds | if refused |
|---|---|---|
| `EFT.GameWorld::get_Instance` / static field | the root of every walk | nothing works; `rootWhy()` says which of the two paths failed and why |
| `GameWorld::MainPlayer` | this player | nothing works |
| `Player::ProceduralWeaponAnimation` | the springs and the frame hook's identity check | nothing actuates |
| `Player::Physical` | stamina, oxygen, hands stamina, exhausted, breath-hold | the shooter reads as permanently rested; fatigue, respiration rate and the hold rebound all flatten |
| `Player::MovementContext` | pose level, tilt, smoothed movement speed | stance and lean multipliers stay at "standing", drift's movement gain never rises |
| `Player::HandsController` → `Weapon` | ergonomics, total weight, recoil stat | handling multipliers default; every weapon feels the same |
| `Player::HealthController` + `IsBodyPartDestroyed` / `IsBodyPartBroken` | fractured and blacked arms | injury multipliers never fire |
| `PWA::HandsContainer` → `HandsRotation` | **the actuator** | the model runs and reaches nothing |
| `HandsContainer::CameraRotation`, `CameraTransform` | view coupling, aim-relative geometry | camera coupling is silently zero |
| `Spring::AddAcceleration(Vector3)` | the one write this mod makes | `actuate` returns immediately; the mod is inert and says so |
| `Spring::Damping` / `ReturnSpeed` / `AccelerationMax` | **the calibration** | falls back to the shipped guesses (7.0 / 0.55 / 12.0) and the log says "(all three are this mod's shipped guesses)" |
| `Player::get_Velocity`, `Transform::get_eulerAngles` | inertia and drift's movement input | inertia never fires; the flick response disappears |

`AddAcceleration` and the two `Vector3` getters go through `bindRaw` — bound by
their native Win64 slot shape rather than by signature, because a 12-byte struct
is passed and returned by hidden pointer. `bindMethod` refuses all three and is
right to.

Three hooks, chosen by what each firing costs:

* `ProceduralWeaponAnimation::LerpCamera` — a **typed postfix**
  (`hookReturnTyped`) where the host offers one, which restores the BepInEx
  original's ordering; a typed prefix, then a plain prefix, on a host that
  refuses. The typed forms also carry `this`, which is how the handler tells
  this player's animator from a bot's — bots have animators too, and every
  firing used to step the whole model.
* `Player::OnMakingShot` — the per-shot kick.
* `ProceduralWeaponAnimation::PhysicalConditionUpdated` — a typed prefix
  carrying the `EPhysicalCondition` mask; falls back to `hookArgs` (JSON), then
  to a bare `hook` with a warning that arm injury will be read from the health
  controller instead.

---

## 5. Gaps

| gap | why it is open | what it costs |
|---|---|---|
| **The damping law is unmeasured.** | It is BSG's integrator; nothing outside the process can see which line they wrote. | A factor of ~100 on everything in the slow band, and the difference between `masterIntensity` 0.1886 and 3.733. |
| **`springs.accelerationPerFrame` is argued, not measured.** | The argument is dimensional: a clamp of 12 is only meaningful at the scale it clamps. **An argument is not a measurement.** | A factor of 60 on the entire drive. |
| **Every `EFT.` name is pre-1.0.** | Post-1.0 is a different build. | Each wrong name is one refused binding, one warning line, and one defaulted input — never a wrong number. |
| **The postfix ordering has never been seen.** | It depends on the host offering `hookReturnTyped`. | On the fallback path the impulse lands one frame's ordering earlier against BSG's own effectors. `AddAcceleration` accumulates rather than sets, so it is an ordering difference, not a different result. |
| **`ShippedReturnSpeed = 7.0` is a guess at BSG's value.** | It is this mod's own config value, used until the live spring can be read. | It is the *only* place that guess is made; everything else derives from whatever number is actually there. |
| **The camera spring's `AccelerationMax` is not modelled.** | This mod does not know what it is. | `cameraCal` carries 0, so `saturation` answers 0 for the view spring and the ceiling on camera coupling is unknown. |
| **No sound, no recoil sample.** | Neither is an input to this model. | Nothing — noted so nobody looks for it. |

What is *not* a gap: the limiter. `model/limits.nim` covers **131 parameters**,
every range is `lo <= hi`, every shipped default sits inside its range and needs
no clamping, no preset needs clamping, out-of-range values are pulled to the
bound and **reported by name with both numbers**, and NaN / ±inf go back to the
shipped default. 37 parameters were swept for the value at which the model stops
behaving; all 37 stay clean well past their allowed range.

---

## 6. What a raid would be the first to disprove

In the order a single raid would produce the evidence:

1. **That anything moves.** One boolean stands between this mod and total
   silence, and the self-test cannot distinguish the two branches — only a
   weapon on a screen can.
2. **That `Damping` is a per-frame fraction.** If the weapon rings for thirteen
   seconds after a flick, this file's overdamped column is fiction and
   `masterIntensity` is twenty times too high.
3. **That the shipped `masterIntensity` of 1.0 is anywhere near right.** It is
   the one value the model says is wrong under *both* damping laws — 0.1886 or
   3.733, never 1.0 — and it ships at 1.0 because shipping either derived value
   would mean committing to an unmeasured assumption.
4. **That the spring constants are 7.0 / 0.55 / 12.0.** They are this mod's own
   config values standing in for BSG's. The first actuation line replaces them,
   and if it prints something else then §1's table, §2's ratios and §3's
   deflections are all stale by the same arithmetic.
5. **That `LerpCamera` is the right frame.** It runs on Unity's main thread and
   it is where the BepInEx original did this work — pre-1.0. If post-1.0 moved
   the weapon animation, the hook takes, the handler runs, and the impulse
   lands somewhere that no longer feeds the weapon.
6. **That refusing is enough.** Every mechanism here is arranged so a wrong
   guess produces a warning and a default. That has been checked against a mock
   runtime, never against a build where a name resolves to a *different* member
   of the right type — which would produce a plausible wrong number and no
   warning at all.
