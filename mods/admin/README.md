# Admin / cheat menu

A fully native, client-side admin panel for post-1.0 Escape From Tarkov (IL2CPP
build `1.1.0.1.46777`). Press **F6** for an in-game menu of togglable cheat
modes; **ESP** and **God mode** default ON, the rest off.

```
aowl build-mod mods/admin      # the mod
aowl build                     # host + overlay (the native HUD lives here)
```

## Why fully native (no managed bridge)

On this build the anti-cheat strips the per-frame `MethodInfo.methodPointer`, so
the managed Unity-thread bridge is dead: **you cannot call a game method**. Two
capabilities remain, and this mod is built entirely on them:

- **Field-offset memory reads/writes.** `il2cpp_field_get_offset` is a metadata
  query, not a stripped method, so resolving a field's offset once and reading
  `*(T*)(object + offset)` works — from any thread. That is the ESP data pass and
  the God mode / stamina writes.
- **Drawing in the game's own `IDXGISwapChain::Present`.** The overlay hooks
  Present exactly once; the ESP boxes and F6 menu are drawn there as a HUD on the
  frame — the same place Steam/Discord and the graphics post-process draw. This
  is a HUD, **not** the mod-manager panel.

So there is no `everyMain`, no `il2cpp_runtime_invoke`, no Unity thread anywhere.

## The two halves and how they meet

| half | where | thread |
|---|---|---|
| **data + cheats** | `mods/admin` (`adm/data.nim`) | host `on_update` — memory reads need no particular thread |
| **render** | the overlay's Present hook (`abi/aowlspt_overlay.h`) | the D3D11 render thread |

They rendezvous through a **named shared-memory region** (`abi/aowlspt_admin.h`,
`Local\aowlspt_admin_shared_v3`) both map by name: the mod publishes a
seqlock-protected frame of pre-projected entities + the capability mask; the
overlay reads it and draws. The overlay also writes its back-buffer size into the
region each frame so the mod projects to the exact resolution the boxes draw at.
The **F6 keypress and menu navigation** are handled in the overlay's WndProc,
which flips the toggles the mod then reads — so the menu the overlay draws and
the mod's behaviour are always one shared state.

### The render path (real, compiles, testable)

`abi/aowlspt_overlay.h` gains an admin HUD drawn inside its existing single
Present hook, independent of the mod-manager panel's visibility:

- `aowl_ov_admin_append()` — ESP boxes (side-coloured, health bar, distance,
  name) in true back-buffer pixels, and the F6 menu at panel scale, using the
  overlay's own proven D3D11 pipeline and 8×16 font.
- present body — draws the HUD when the F6 menu is open or ESP is live in a raid,
  forcing a rebuild so per-frame ESP is not held by the panel's geometry cache.
- WndProc — F6 toggles the menu (independent of the panel); ↑/↓ move,
  Enter/Space/←/→ toggle the selected mode, only while the menu is open.
- coexists with the graphics post-process's `g_ov_prePresent` slot: the HUD is an
  additive draw *inside* the overlay body, not a second Present hook.

Verified to compile via the D3D11 test stand-in (`tests/overlayhost`), which is
how the repo tests `aowlspt_overlay.h`.

### The data path (real, verified names for build 1.1.0.1.46777)

`adm/data.nim` walks the world by field offset only, and the names it uses were
**verified against the decrypted global-metadata** for this exact build with
`tools/il2cpp_resolve.py` (the resolver that reproduces the BE-bypass RVAs
byte-for-byte) plus a field dumper over the same metadata. Offsets still resolve
*by name* at runtime, so a mismatch degrades rather than misreads.

Confirmed and wired:

| member | verified name | use |
|---|---|---|
| `EFT.GameWorld` | `RegisteredPlayers` / `AllAlivePlayersList` (List<>), `MainPlayer` | the player walk |
| `EFT.Player` | `<CameraPosition>k__BackingField` (Vector3), `<AIData>k__BackingField`, `Physical`, `_healthController` | position, AI flag, stamina, health |
| `Stamina` | `Current`, `TotalCapacity` | infinite stamina |
| `EFT.CameraControl.CameraManager` | static `instance`, `<Camera>k__BackingField` | the camera |
| `EFT.Player::ApplyDamageInfo` | RVA `0x731480` (prologue `48 89 5C 24 20 …`) | God mode byte-patch |
| `EFT.Player::ReceiveDamage` | RVA `0x6F8D10` | alt God mode target |

**What works now, and the two documented gates:**

- **God mode — works.** A revertible static byte-patch on `ApplyDamageInfo`
  (`xor eax,eax; ret`), resolved by RVA, applied from any thread with no world
  needed. It is *global* (all players take no damage — the local player is the
  point, bots are a side effect); a player-scoped version needs the
  health-controller body-part layout. Reverted on unload.
- **ESP data + stamina — real names, gated on two runtime-resolution steps** that
  degrade safely (ESP dark, never a crash):
  1. **The GameWorld singleton** lives in `Comfort.Common.Singleton<GameWorld>.
     _instance` — a static on a *generic instantiation*, which `findClass`
     cannot name. Acquiring it needs the generics API or the bridge's
     Unity-thread reflection. Until then there is no player list.
  2. **The camera VP matrix** — `UnityEngine.Camera` has no managed matrix field;
     it is read from the native camera (managed `Camera` + `0x10` → native, then
     `+ VpNativeOff`). `VpNativeOff` is the one UnityPlayer-side offset not in
     il2cpp metadata, validated at runtime (finite, bounded) so a wrong value is
     rejected, not drawn. Set it from a UnityPlayer dump / in-raid scan.

  Both gates are one-line `const` edits at the top of `adm/data.nim`; when they
  land, ESP boxes project with no other change.

## Safety guards

- **Every memory read is address-checked** (`VirtualQuery`, committed +
  readable + in-region) before dereference, so a wrong offset or a moved object
  is a zero, never a fault.
- **Seqlock** on the published frame — a half-written frame is retried, not
  drawn.
- **Capability-gated** — a mode whose field did not resolve is drawn dim and its
  toggle does nothing.
- **No managed calls** anywhere — the thing that crashes this client is never
  done.
- **Absent region / runtime** — a no-op HUD and an untouched game.

## The toggles

`ESP`, `God mode` (both on by default), `Infinite stamina`, `No recoil/sway`,
`No weight`, `Instant heal`, `Unlimited ammo`, `Thermal vision`, `Night vision`,
`Fly/noclip`, `Teleport to marker`, `Set time of day`. ESP + God mode + stamina
have their write/read paths wired (capability follows whether the field
resolved); the rest are declared, read from config/F12, and drawn "unavailable"
until their offsets land. Defaults live in `config.json` and the F12 schema;
after load the F6 menu owns them.

## Files

- `abi/aowlspt_admin.h` — the shared-memory surface: toggles, the ESP frame,
  projection, guarded raw field reads, screen-size handoff.
- `abi/aowlspt_overlay.h` — the native HUD (ESP + F6 menu) inside the Present
  hook (additive edits, marked).
- `admin.nim` — map the region, seed/apply config, the `on_update` data+cheats
  pass, the F12 schema.
- `adm/shared.nim` — the nimony face of `aowlspt_admin.h`.
- `adm/data.nim` — the field-offset ESP data pass + God mode / stamina writes.
- `config.json` — initial toggle states.
