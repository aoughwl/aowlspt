# Running Escape From My Basement on SPT 4.1.5 — the port plan (LAST step)

The user's instruction: build the agnostic backend first, worry about SPT
last. This file is the plan so the last step is one attempt, not a research
project. Nothing in it has been built. Everything it names as measured says
where.

## What the SPT side needs, and what it does not

The whole brain, world, speech and encounter logic lives in
`mods/basement` running inside `aowlspt-backend.exe`. **SPT's own server is
left alone** — it keeps serving the game's profile, trading and raid start
exactly as today. `aowlspt-backend` becomes a **sidecar** on another port
(default `6969` is what the aowlspt install uses; on an SPT box pick `6970`)
serving only `/aowlspt/basement/*` (and optionally `/aowlspt/voice/*`).

So the port is **one BepInEx client plugin** implementing
`CLIENT-CONTRACT.md`, plus a sidecar launcher. No SPT server mod is needed
for the RPG loop. (The old `EscapeFromMyBasement.Server.csproj` scaffold is
superseded and stays unused.)

| Piece | Built on | Notes |
|---|---|---|
| `Basement.Client` BepInEx plugin | `netstandard2.1`, BepInEx 5, references from `D:\SPT415` (`EscapeFromTarkov_Data\Managed`, `BepInEx\core`, `BepInEx\plugins\spt`) — copy the csproj shape of `C:\Users\savant\Projects\SPT-FOV-Fix\FOVFix.csproj` (MEASURED 2026-09-06: it targets `D:\SPT415`) | Mono, so `Assembly-CSharp` types are usable directly: `Singleton<GameWorld>.Instance.AllAlivePlayersList`, `Player.Position`, `BotOwner`, `AudioSource` — the parts EFMB's old `NpcVoiceSystem.cs` already had working on 0.16.9 |
| Sidecar launcher | the plugin's `Awake` starts `aowlspt-backend.exe --root <dir with mods/basement> --port 6970` if `GET /aowlspt/basement/status` does not answer | `mods/basement` must load with NO `mods/tarkov` present; verify by staging a root with only basement (the backend self-test needs tarkov, ordinary serving should not — UNVERIFIED, check first) |
| Always in raid | the plugin skips the menu: on `MenuScreen` shown, read `GET /aowlspt/basement/spawn` and drive SPT's own offline-raid start with that map (SPT 4.x exposes the raid settings through `TarkovApplication`/`MainMenuController`; the exact members are to be read from `Assembly-CSharp` of 4.1.5, never assumed) | the aowlspt equivalent is `mods/autoraid`, PROVEN 2026-09-05 |
| Facts in (`/observe`) | `Update()` at 10 Hz: nearest alive bot in the view cone → `player_seen`; `Player.HandsController` aiming state → `player_aimed_at`; shot fired hooks (SPT's `spt-reflection` patches) → `player_fired`; damage → `player_hit`; `raid_started`/`raid_ended` from `GameWorld` lifecycle | one HTTP POST per fact, fire-and-forget, `HttpClient` |
| Directives out (`/events`) | one long-poll loop on a background thread, `wait=20000`; dispatch on the main thread via a queue drained in `Update()` | `say` → play wav at the bot's position (`AudioClip` from the wav, `spatialBlend 1`, EFMB's code); `npc.follow/hold/goto/attack` → `BotOwner.Mover.GoToPoint` / `BotOwner.Memory` targets (SAIN-compatible); `player.captive` → hide weapon slots via the inventory controller and enforce the leash by teleporting back / applying a stun; `group.spawn` → SPT's `BotSpawner` |
| Speech in | push-to-talk key; capture with EFMB's `recorder.exe` (winmm, works while the game holds the mic) or Unity `Microphone` if SPT's client allows it; post 16 kHz PCM chunks every 500 ms to `/speech/chunk` with `final` on key-up | progressive: partials arrive on the stream as `heard.partial` |
| Bot identity | the backend's `person.id` is stable; the plugin maps a spawned bot to a person when it honours `group.spawn`/`world/people` (keep a `Dictionary<int profileId-hash, personId>`) — EFMB's fatal flaw was keying memory on a per-raid GUID | |

## Build and install (when the time comes)

```
dotnet build client/Basement.Client.csproj -c Release   # OutDir = D:\SPT415\BepInEx\plugins\
copy backend\bin\aowlspt-backend.exe + a root with mods\basement to D:\SPT415\aowlspt-sidecar\
```

Config: `BepInEx\config\aowl.basement.cfg` with `BackendUrl`, `PushToTalkKey`,
`AutoRaid` (bool), `Preset`. **No API key in the plugin or its config** —
the backend reads `ANTHROPIC_API_KEY` from the environment of the sidecar.

## Verification that can fail

* plugin loaded: `BepInEx\LogOutput.log` has `aowl.basement` and the sidecar
  `status` answered `enabled:true`.
* facts flow: `GET /aowlspt/basement/status` shows the `observe` counter
  rising while the player looks at a bot (negative control: it does not
  rise while looking at nothing).
* directives flow: a `say` produced by `POST /say` from curl is played in
  game within 2 s and acked (`pendingAcks` empty).
* always-in-raid: from a fresh launch, the player is in a raid on the map
  `spawn` named without touching the mouse.
