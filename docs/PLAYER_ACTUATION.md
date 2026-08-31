# In-raid actuation of the local player (`pact`)

The primitives that let a test drive the local player with nobody at the
keyboard: walk, look, fire, aim, pose, lean, the game's own input-command
channel (reload / weapon swap / inventory), and a closed-loop magazine
unload+load cycle.

Two files, and both are worth reading before calling anything:

| file | what is in it |
|---|---|
| `abi/aowlspt_pact.h` | the 31-row byte-verified call table, the derivation of every calling shape from the compiled bodies, the measured field offsets, and every refusal with its reason |
| `host/Aowlspt.Host.Il2Cpp/pact.nim` | the guard, the flag, the fault budget, the queue, the readbacks and the counters |

Flag: **`playerActuation`**, default **OFF**.
`python tools/hostcfg.py set playerActuation on`.

**This document is the HOST side.** For the automation library that drives these
primitives from a script — the typed verbs, their arguments, their failure modes
and what each one actually proves — see **`docs/AUTOMATION-API.md`**. In
particular it records which verbs are *verified* (`walkAndSee`, `magCycle`) and
which are **issue-only** (everything else): pact has no readback for rotation,
trigger, aim, stance or the `ECommand` channel today, so a PASS on those means
the host accepted the call and nothing more.

A script writes `withActuation(s)` and gets the three flags armed *before boot*
(`playerActuation`, `liveInspector`, `liveInspectorWrite` — all read at boot, so
arming them against an already-running client is impossible and is announced
rather than faked).

---

## 1. Can the local player ride the bot drive path? No. Measured.

This was the question the work started from, so it gets answered first.

`mods/sain/client/drivecalls.nim` drives bots through seven RVAs. They split
cleanly in two:

| RVA | member | transfers to the local player? |
|---|---|---|
| `0x5238930` | `UnityEngine.AI.NavMesh::SamplePosition` | **yes** — a static, receiver-agnostic |
| `0x5328830` | `UnityEngine.Physics::Raycast` | **yes** — same |
| `0x1A2D700` | `BotMover::Sprint` | **no** |
| `0x1A2D600` | `BotMover::Stop` | **no** |
| `0x1A3B690` | `BotSteering::LookToPoint` | **no** |
| `0x1AF7940` | `ShootData::Shoot` | **no** |
| `0x81C970` | `EFT.BotOwner::StopMove` | **no** |

The five that do not transfer are all reached through `EFT.BotOwner` field
offsets — `get_Mover` @`0x80F920` (+0x3D0), `get_Steering` @`0x80D8E0`
(+0x148), `get_ShootData` @`0x80E8D0` (+0x280). The local player is an
`EFT.Player`. It is not a `BotOwner`, it does not hold one, and
`EFT.Player::get_AIData` @`0x7267B0` reads NULL for it — which is the same
discriminator `botdiag` already uses to tell a bot from you.

Handing an `EFT.Player*` to any of the five is **type confusion**: the callee
reads a `BotOwner` field offset off a `Player`, gets a plausible pointer from an
unrelated field, and dereferences it. `VirtualQuery` cannot see that and neither
can a null check. It would not refuse; it would crash, or silently drive
garbage.

**So the fold-together the user asked for is a shared VERB VOCABULARY over two
backends, not a shared call table.** One `moveTo` / `lookAt` / `fire` / `reload`
surface, dispatching to `sain` drivecalls when the subject is a `BotOwner` and to
`pact` when it is the local `EFT.Player`. Nothing in `pact` should ever be handed
a `BotOwner` and nothing in `drivecalls.nim` should ever be handed a `Player`.

The local player's own surface is **strictly richer** than the bot one: the bots
have five verbs, the local player has `Move`, `Rotate`, `Jump`, `ChangePose`,
`ToggleProne`, `EnableSprint`, `ToggleLean`, the whole `FirearmController`, the
two inventory magazine calls, and an 88-verb input command funnel.

---

## 2. The API

`pactPost` and every convenience poster below **touch no game memory** and
therefore cannot fault. They are safe from any thread and safe inside a caller's
own `aowl_p_p_seh` — which matters, because that guard is not re-entrant. They
enqueue; the guarded main-thread drain executes.

```nim
pactMove(x, y: float64; frames: int32): bool
```
Walk. `x` is strafe (−1 left … +1 right), `y` is forward (−1 back … +1 forward),
in the game's own normalised input units — the same `Vector2` `Player::Move`
receives from the input tree. **Held for `frames` frames**, because `Move` is an
*input*, not a command: it dies the moment it stops being re-asserted, so the
drain re-issues it every frame for the requested duration.

```nim
pactRotate(dx, dy: float64): bool
pactLookAt(x, y, z: float64): bool
```
Look by a delta, or toward a world point. `pactLookAt` uses the game's **own**
conversion, `MovementContext::CalculateLookAtDirection` @`0x88C080`, rather than
trigonometry of ours, so the units cannot disagree with the game's. Both go
through `Player::Rotate` with `ignoreClamp = false`, so the game's pitch clamp
stays in force and a script cannot drive the head through the floor.

```nim
pactJump(): bool
pactPose(delta: float64): bool     # negative lowers, positive raises
pactProne(): bool
pactSprint(on: bool): bool
pactLean(dir: float64): bool       # -1 left, 0 centre, +1 right
```

```nim
pactFire(on: bool): bool
pactAim(on: bool): bool
pactFireMode(mode: int32): bool
```
`pactFire` is a **latch, not an edge**: post `true`, wait, post `false`. All
three require a firearm in hands and refuse loudly otherwise — see §4.

```nim
pactCommand(cmd: int32): bool
```
Issue one `ECommand` through the game's own input funnel,
`GamePlayerOwner::TranslateCommand` @`0xB2B2F0`. **This is the highest-value
verb here**: one call covers 88 commands. The ones a test most wants:

| ordinal | command |
|---:|---|
| 1 / 2 | `ToggleShooting` / `EndShooting` |
| 16 | `ReloadWeapon` |
| 19 | `QuickReloadWeapon` |
| 20 | `ChangeWeaponMode` |
| 22 | `ToggleDuck` |
| 28 | `ToggleProne` |
| 36 | `ExamineWeapon` |
| 37 | `ToggleInventory` |
| 40 | `Jump` |
| 41 / 42 / 43 | `SelectFirstPrimaryWeapon` / `SelectSecondPrimaryWeapon` / `SelectSecondaryWeapon` |
| 58 | `CheckAmmo` |

`CanTranslateCommand` @`0xB2A830` is called first, so "the game would not accept
this command right now" is reported as a distinct, *game-sourced* answer rather
than as our failure.

```nim
pactMagCycle(): bool
pactWait(frames: int32): bool
pactStatus(): string
```

---

## 3. `pactMagCycle` — the user's own example

> "i shouldn't have to unload the magazine and reload the ammo for something to
> trigger for you to observe, that should be automated"

`pactMagCycle` unloads the magazine currently in the weapon and loads the same
ammunition back into it, driving `LoadMagazineProcess` — which is exactly what
`mods/ammoloading` hooks.

The chain reaches a **type-correct `Ammo` with no inventory-grid walk at all**,
which is the whole reason this was buildable safely:

```
Player.HasFirearmInHands()   @0x727770   <- THE TYPE GUARD, not optional
Player.get_HandsController() @0x727850   -> AbstractHandsController
FirearmController.get_Item() @0x7771D0   -> Weapon
Weapon.GetCurrentMagazine()  @0x10B48F0  -> Magazine
Magazine.get_Count()         @0x10982C0  -> int   (n0, the READBACK baseline)
Magazine.FirstRealAmmo()     @0x10982F0  -> Ammo  (no grid walk needed)
Player.get_InventoryController() @0x727B20
  PlayerInventoryController.UnloadMagazine(mag, false)      @0x766BC0
  PlayerInventoryController.LoadMagazine(ammo, mag, n0,false)@0x766930
```

State machine, with a frame deadline on every waiting step:

1. capture; refuse if `n0 <= 0` (nothing to unload) — counted **NEVER ISSUED**
2. issue `UnloadMagazine`
3. poll `Magazine.get_Count()` until `0`, deadline 180 frames (~3 s)
4. re-validate the `Ammo` pointer, then issue `LoadMagazine(ammo, mag, n0)`
5. poll `Magazine.get_Count()` until `>= n0`, same deadline

Both inventory calls return `Task<IResult>` and are **asynchronous**. The task is
discarded without being inspected — nothing is retained and no GC handle is
needed. Completion is observed only by polling a number the game maintains and
we never write. A partial load is reported as a **failure**, on purpose: "some
rounds went in" is not the state that was asked for.

---

## 4. Acceptance — four outcomes, never two

`pactStatus()` is the counter line a scripted run prints:

```
pact armed=31/31 rejected=0 raid=DEPLOYED player=ok owner=corroborated
  | asked=14 took=11 noeffect=2 never=1 qdrop=0
  | magcycles=1 magok=1 magfail=0 (unloaded 30 rounds and loaded them back;
    Magazine.Count returned to 30)
```

| counter | meaning |
|---|---|
| `asked` | a call was actually made into the game |
| `took` | a **readback of the finished state** showed the intended change |
| `noeffect` | the call was made and the readback did **not** change |
| `never` | dropped before the call, with a stated reason |

These are four mutually exclusive outcomes and they do not sum to anything
convenient on purpose. **A run with `asked=0` is INCONCLUSIVE — never PASS.**
"Issued but nothing moved" (`noeffect`) reads differently from "never issued"
(`never`), which was the explicit requirement.

The readbacks are properties of the finished state, never of our own write:

| actuation | readback |
|---|---|
| move | `Player::get_Position` before, and 30 frames later; the counter is **metres actually travelled**. Below 0.35 m is counted as NO EFFECT, because idle settle would otherwise make the check unable to fail. |
| sprint | `Player::get_IsSprintEnabled` |
| aim | `FirearmController::get_IsAiming` |
| fire mode | the game's own `bool` return from `ChangeFireMode` |
| command | `ETranslateResult`; ordinal 0 is read conservatively as NO EFFECT |
| magazine | `Magazine::get_Count`, polled, against the count captured before the unload |

Three states everywhere, not two: a readback that could not be taken
(`get_Position` refused, `get_Count` returned −1) increments **nothing** and
records an INCONCLUSIVE refusal string. `-1` is never collapsed into `0` — a
magazine legitimately holds 0 rounds.

---

## 5. Refusals, by name

| refused | why |
|---|---|
| `FirearmController::CanPressTrigger` @`0x6B65D0` | compiles to `B0 01 C3` = `mov al,1; ret`, **shared by 584 methods**. A folded constant-true. It binds, verifies and can only ever say yes. |
| `FirearmController::ReloadMag` / `QuickReloadMag` / `ReloadWithAmmo` / `ReloadBarrels` | every overload takes one or two managed `Callback` delegates. Constructing one needs runtime managed delegate construction, which this repo records as *plausible but unverified*. Passing NULL was not measured. **Use `ECommand` 16 / 19 instead** — the same operation through the game's own entry point. |
| `EFT.Player::Proceed(Weapon, Callback<IFirearmHandsController>, bool)` @`0x742710` and its ten siblings | same `Callback` problem. **Use `ECommand` 41 / 42 / 43** for weapon swap. |
| `EFT.Player::Create`, `MovementContext::Create` | `RVA=None` in the metadata (`mvar` / generic); not resolvable offline. |
| a by-name `GetComponent` for `GamePlayerOwner` | token-gated on this build; the failure mode is a uniform random **non-zero** pointer, so a nil check passes and the first dereference kills the client. Replaced by a capture detour — see §6. |

Three rows are **CALL-ONLY** — safe to call, never to detour, because calling a
shared RVA is correct code for the receiver passed while detouring one has
unbounded blast radius:

* `Player::get_MovementContext` @`0x690D20` — shared with **135** other
  one-instruction getters. Read raw at `+0x60` instead.
* `Player::get_HandsController` @`0x727850` — shared, owners 3.
* `FirearmController::get_IsAiming` @`0x777A80` — shared, owners 3.

---

## 6. Reaching `GamePlayerOwner`, and why it is a detour

There is **no** field on `EFT.Player` that points at the `GamePlayerOwner`;
`holdersof GamePlayerOwner` returns only compiler closure classes,
`RaidDialogEntryPoint._gamePlayerOwner` and
`EftBattleUIScreenController.<Owner>k__BackingField`, none of which we hold. A
by-name component lookup is lethal on this build.

So the instance is **captured, not walked**: a read-only detour on
`EFT.GamePlayerOwner::LateUpdate` @`0xB29130` (UNIQUE, owners=1, real body)
records `RCX` and returns. It writes nothing, calls nothing, allocates nothing
and iterates over nothing, and it runs on the Unity thread by construction.
Nothing else in this repo detours that RVA — checked — so the double-detour
trampoline hazard does not apply. If that ever changes, `pact` must ride the
existing detour as a drain rather than bind a second one.

The capture is then **corroborated**: `GamePlayerOwner::get_MyPlayer` @`0xB280D0`
must be pointer-identical to the `GameWorld.MainPlayer` we validated
independently, or every `ECommand` is refused. That check can fail, which is the
point.

Until the detour has fired at least once, the command channel reports
**NOT-YET-CAPTURED — inconclusive**, never a refusal about the build. Movement,
look, fire, aim and the magazine cycle do not use this receiver and are
unaffected.

---

## 7. Safety, and the one thing that is inferred

Every hop is `VirtualQuery`-guarded separately (`a->b->c` is three checks). The
whole body is under **one** `aowl_p_p_seh` and nothing opens a second — which is
why the public API is a queue. Iteration is capped everywhere (32-slot ring, 4
entries per frame, a frame deadline on every wait). Default OFF. Self-disables
after 8 faults, a whole-file budget because a wrong calling convention would not
confine itself to one channel.

The local player is re-derived and re-validated **every tick**, never trusted
across frames: readable → Unity-alive (`m_CachedPtr`; a destroyed object stays
readable and dies on the next internal call) → klass word matches the one pinned
on first acquisition → `get_IsYourPlayer()` true → `AIData` null.
`get_IsYourPlayer` is called first on purpose: it compiles to
`movzx eax,[rcx+0xB89]; ret`, a pure byte read that cannot dispatch anywhere.

**The one inference, stated rather than hidden.** `pactMagCycle` assumes the
`Ammo` object's identity survives the unload — that an inventory *move* does not
destroy and recreate the managed item. That is inferred, not measured. Step 4
re-validates the pointer and **refuses loudly** rather than passing a stale one
into `LoadMagazine`.

**The residual risk, likewise stated.** `PlayerInventoryController::LoadMagazine`
and `::UnloadMagazine` are `VIRTUAL` and not sealed, so a direct call at the RVA
runs *that* body even for a derived receiver that overrides it. The receiver
comes from `Player::get_InventoryController` on the local player, which in an
offline raid is a `PlayerInventoryController`; this build gives us no ungated way
to ask an object its class. The klass word is pinned and a change refuses, which
catches a swap but not a wrong first answer.
