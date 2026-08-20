# Admin / cheat menu

An in-game admin panel for post-1.0 Escape From Tarkov (IL2CPP build
`1.1.0.1.46777`), running as a native aowlspt client mod. Press **F6** to toggle
the menu; **ESP** and **God mode** are ON by default, every other mode is off.

```
aowl build-mod mods/admin
```

## The one rule everything is built around

**A managed IL2CPP call is only legal from Unity's own thread.** Making one from
the host's thread crashes this client. So all of this mod's per-frame work — the
ESP world walk, God mode, stamina — runs inside `everyMain`, which the host
drains from a per-frame game method (i.e. on Unity's thread), and **only after**
the host confirms that drain has actually fired (`aowlspt.host::main_thread` →
`bound:true`). Until that gate is affirmative the mod touches nothing managed:
the menu still opens (its input is a `GetAsyncKeyState` read, not a managed
call), and every mode reads "unavailable". No bound Unity thread → no cheat → no
crash.

## Strategy: managed reflection on the Unity thread, not raw memory

Two implementations were possible: (1) run cheat logic on the Unity thread via
the host's main-thread bridge and reach the game through the IL2CPP runtime, or
(2) a classic internal cheat reading `GameAssembly.dll` memory through hardcoded
struct offsets.

**This mod uses strategy 1.** The reason is concrete: this repo has *no* offset
tooling and *no* stored offsets — no `dump_types.py`, no GameWorld/Player/
HealthController/Camera offset table anywhere. Everything in aowlspt reaches the
game by IL2CPP reflection (`il2cpp_field_get_offset` → `object+offset`) and bound
managed calls, and the main-thread bridge that makes that safe per-frame is
already merged. Strategy 2 would have meant first building an offset dumper from
decrypted metadata — a separate project — for a fragility (fixed offsets break
every patch) the reflection path does not have. The proven client mods (`fov`,
`sain`, `morebots`) all take strategy 1; this follows them.

Godmode's *native byte-patch* alternative (like the BE-bypass in
`abi/aowlspt_beclient.h`) was considered and is the right tool once the damage
method's RVA on this exact build is known — but that RVA is not in the repo, so
godmode is done as a managed damage-suppression hook instead, which needs no RVA
and degrades gracefully.

## The split: what is real, what is pending

Because rendering must go through the **game's own** rendering (never the host's
D3D11 overlay), the work divides along the frame's phases:

### Runs now — managed reads/writes on Unity's thread

| piece | how |
|---|---|
| Toggle framework + F6 menu state | `adm/state.nim` — pure state + `GetAsyncKeyState` input, safe from any thread |
| ESP **data** pass | `adm/world.nim` — `GameWorld.Instance` → `AllAlivePlayersList` → each `Player`'s `get_Position`/`get_IsAI`/`get_Side`, plus the camera's `worldToCameraMatrix`×`projectionMatrix`, projected to screen |
| God mode | `adm/cheats.nim` — a prefix hook on the damage method, suppressing only the local player's hits while the toggle is on |
| Infinite stamina | `adm/cheats.nim` — per-frame write of the local player's `Physical.Stamina.Current` back to full |

Each is armed only when every binding it needs resolved, sets its own capability
flag, and reports "unavailable" otherwise. `adminDiag()` (logged ~2 s after a
raid starts) prints every binding's own account.

### Pending — the pixels

The actual **drawing** is the pending part, and honestly so. Native Unity
rendering is *render/GUI-phase* work: `GL` immediate mode only rasterises inside
camera rendering, and post-1.0 there is no `MonoBehaviour`/`OnGUI` to receive a
GUI event (see `docs/IL2CPP.md`). The host's bridge drains in the **Update**
phase, so a `GL`/`GUI` call from `everyMain` is on the right thread at the wrong
point in the frame and paints nothing.

`adm/render.nim` is therefore written **against the interface it needs** — a
callback that fires *during rendering* on Unity's thread — and reports every
frame whether that callback exists yet (`renderReady()` / `setRenderPhase()`):

- the ESP geometry is computed and counted every frame (proving the data pass
  works even with nothing on screen);
- the menu is laid out and logged to `Player.log` (so it is observable now);
- `UnityEngine.GL` is *probed* so the diag says whether the drawing surface is
  even present on this client.

The moment a render-phase drain lands — either the bridge growing a render-phase
queue, or a detour of a render-phase method once its name is confirmed on a live
build — `drawEspGL`/`drawMenu` already have the geometry and the surface and go
live with **no change to the rest of the mod**. The menu's text rows are the one
piece that additionally needs a GUI context (IMGUI), which is the genuinely
absent post-1.0 surface; the ESP boxes need only `GL`.

## The object-model path (unverified against BSG's live client)

Every name below is from the pre-1.0 C# surface; post-1.0 is a different build.
A wrong name is a refused binding with a `why` line and a mode that reads
"unavailable" — never a wrong write or a crash.

- **ESP:** `EFT.GameWorld::get_Instance` (static) → `get_MainPlayer`,
  `get_AllAlivePlayersList` → `List<>::get_Count`/`get_Item` → per player
  `get_Position` (a `Vector3`, read by its native hidden-return-pointer shape,
  exactly as `mods/morebots` does), `get_IsAI`, `get_Side`. Camera via
  `UnityEngine.Camera::get_main`, falling back to
  `EFT.CameraControl.CameraManager::get_Instance`→`get_Camera`; then
  `get_worldToCameraMatrix` and `get_projectionMatrix` (`Matrix4x4`, same shaped
  read), multiplied to a world→clip matrix and projected in `world.nim`.
- **God mode:** a prefix hook (`hookArgs` + suppression) on the first of
  `EFT.Player::ApplyDamageInfo`, `EFT.Player::ReceiveDamage`,
  `EFT.HealthSystem.ActiveHealthController::ApplyDamage` that binds; the
  suppression value is chosen from the method's real declared return type.
- **Stamina:** `EFT.Player::get_Physical` → `EFT.Player.Physical::get_Stamina` →
  the `Current` field on the stamina value (`GStruct.StaminaValues` — the struct
  name is a guess and refuses cleanly if wrong).

## Safety guards

- **Main-thread gate** — no managed call until `aowlspt.host::main_thread`
  reports `bound:true`.
- **Graceful degradation** — every binding is guarded; a refusal disables the
  mode and marks it "unavailable" rather than guessing. An empty world, no
  camera, or a wrong name is a menu that does nothing, never a fault.
- **God mode is scoped** — it suppresses damage only when `this` is the local
  player, so bots still take hits and the raid still behaves.
- **Value-type reads are shape-checked** — `Vector3`/`Matrix4x4` are read by the
  Win64 hidden-return-pointer ABI, into oversized buffers so a larger-than-
  expected value type cannot overrun.
- **Read-only ESP** — the world pass writes nothing into the game.

## The toggles

`ESP`, `God mode` (both on by default), `Infinite stamina`, `No recoil/sway`,
`No weight`, `Instant heal`, `Unlimited ammo`, `Thermal vision`, `Night vision`,
`Fly/noclip`, `Teleport to marker`, `Set time of day`. The first two plus
stamina are wired; the rest are declared, read from config/F12, and reported
"unavailable" until their managed writes are bound — the safe-by-default
contract.

Menu keys: **F6** open/close · **↑/↓** move · **Enter/Space/←/→** toggle the
selected mode. Defaults live in `config.json` and the F12 schema in `admin.nim`;
after you change a toggle in the menu it lives in the mod's own state.

## Files

- `admin.nim` — entry, config, F12 schema, the main-thread gate, the per-frame tick.
- `adm/state.nim` — toggles, capability flags, menu, keyboard.
- `adm/world.nim` — the ESP data pass and projection.
- `adm/cheats.nim` — God mode and stamina.
- `adm/render.nim` — native rendering, gated on the pending render-phase hook.
- `config.json` — initial toggle states.
