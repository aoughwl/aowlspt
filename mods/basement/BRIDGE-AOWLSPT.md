# The aowlspt client bridge for aowl.basement — design (build after the host verbs land)

`CLIENT-CONTRACT.md` is the engine-agnostic spec. This file is how the
aowlspt IL2CPP host side implements it. Nothing here is built yet; every
"measured" line names its source.

## Shape: one DLL, two sides

`mods/basement` becomes `sides = {sideServer, sideClient}` like
`mods/autoraid` (measured precedent: `mods/autoraid/ar/loadoutclient.nim`
header — same DLL, `onLoad` branches on `side()`, the two halves talk over
the bus and the wire). The client half lives in `mods/basement/bridge/`:

| file | job | primitive it needs | status of the primitive |
|---|---|---|---|
| `bridge/link.nim` | the long-poll loop: `GET /events?since=&wait=20000` through `aowlspt.host::http`, dispatching each directive; `POST /observe` fire-and-forget; `POST /ack` | `aowlspt.host::http` + event `host.http.done` (agent G, flag `hostHttp`) | being added 2026-09-06 |
| `bridge/see.nim` | facts: `player_seen` (nearest alive bot in the view cone), `player_aimed_at`, `player_fired`, `player_hit`, `player_moved`, `raid_started/ended`, `npc_died` | the live bot census (`mods/sain/client/bridge.nim` reads bots, fact #226; `docs/BOTNAV.md` §1 BotOwner layout), player position + look (`MovementContext+0x3D0 _lookDirection`, session-status maps note), raid phase (`aowlspt.host::raid_phase`, proven) | census + phase exist; aim/fire hooks are RVA-gated (`docs/VOICE_RVA.md` has BotTalk; player fire hook to be measured) |
| `bridge/hear.nim` | push-to-talk: keybind down → `POST /speech/ptt {session, state:"down"}`; the BACKEND records (recorder.exe, same machine) and runs progressive STT; key up → `state:"up"` = final | host keybind settings (`keybindSetting`, used by autoraid's key rows) | exists |
| `bridge/say.nim` | `say` segments → `aowlspt.host::play_wav {path}` in seq order; non-spatial first | `aowlspt.host::play_wav` (agent G, flag `hostPlayWav`) | being added |
| `bridge/act.nim` | `npc.follow/hold/goto/attack/stand_down` → `mods/sain` driver (`docs/BOTNAV.md` §3: `BotOwner.Mover.GoToPoint` kind 15 @0x81CB40, directly callable, verified) via the bus event `sain.command {botId, verb, x,y,z}` (to add on the sain side); `group.spawn`/`loot.spawn` are NOT the client's job on aowlspt — the emulator plants them into the raid payload (`tarkov.loot.plant` / `tarkov.bots.plant`, agent F) | sain driver actuation is fact #227 (does not yet move bots live) | contract only |
| `bridge/captive.nim` | `player.captive`: hide weapon slots is a profile-side operation on aowlspt (the backend edits the profile through `mods/tarkov`'s item builder over the bus, the way `autoraid.loadout.apply` does), and the leash is enforced by the backend re-checking `player_moved` and issuing `hud.note` + `npc.attack` on a break; the client only renders `hud.note` | `ui.show` bus / overlay text | overlay exists (maps HUD) |
| `bridge/spawn.nim` | always-in-raid: at MENU, `GET /spawn` → `autoraid.machine.arm(map, side, "basement", why)`; at RESULTS, straight back to MENU → next `/spawn` | `mods/autoraid` (PROVEN 9/9 entries, 8/9 exits 2026-09-05) | exists; needs a bus entry point `autoraid.arm {map}` instead of only the cmdline token |

## Backend-side additions this needs (server half, small)

* `POST /aowlspt/basement/speech/ptt {session, state}` — on `down` spawn the
  recorder (aowl.voice's `record` pattern: `recorder.exe <wav> <seconds>`,
  the winmm exe that exists because the game holds the mic); feed the
  growing file through `sttSessionChunk` every `sttPartialMs`; on `up`
  stop and send `final`. Same route shape on SPT, where the plugin may
  instead post chunks it captured itself.
* `basement.raid.request` is already emitted with `player.spawn`; the
  client half consumes it through `/spawn` rather than the bus (the bus
  does not cross processes).

## Order of work

1. host verbs (G) → 2. `bridge/link.nim` + `say.nim` + `spawn.nim` (a
   `say` from curl is heard in game; the menu is skipped) → 3. `see.nim`
   from the census (people know you are looking at them) → 4. `hear.nim`
   (talk back) → 5. `act.nim` once the sain driver actuates.

## Verification that can fail

* `say` from curl → `play_wav` accepted → `ack` cleared within 2 s (negative:
  with `hostPlayWav` off the ack carries `ok:false why:flag`).
* `player_seen` counter on `/status` rises only while the census has a bot
  inside the cone (negative: looking at nothing keeps it flat).
* boot with `enabled:true` → `AutoRaid CMDLINE VERDICT PASS` with the map
  `/spawn` named, no `-aowl.raid` token on the command line.
