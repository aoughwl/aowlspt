# Basement.Client -- the SPT 4.1.5 client for aowl.basement

A BepInEx 5 / Mono plugin implementing `../CLIENT-CONTRACT.md` against the
aowlspt backend running as a **sidecar** (`../PORT-SPT415.md`). SPT's own
server is untouched; the brain, world, speech and encounter logic all live in
`aowlspt-backend.exe --root <sidecar root> --port 6970`, and this plugin only
reports facts, executes directives, plays wavs and forwards push-to-talk.

Status 2026-09-06: **compiles (0 warnings, 0 errors); never yet loaded by a
live SPT client.** Every EFT member it touches was verified offline against
`D:\SPT415\EscapeFromTarkov_Data\Managed\Assembly-CSharp.dll` with
`MemberCheck/` (Mono.Cecil). Nothing below is a live measurement unless it
says MEASURED.

## Layout

Since 2026-09-07 this is TWO plugins plus an example (see `API.md`):

```
spt/
  NuGet.Config                   nuget.org + https://nuget.bepinex.dev (BepInEx.* are NOT on nuget.org -- MEASURED NU1101)
  Aowl.sln                       Aowl.Api + Basement.Client + Examples/HelloAowl
  API.md                         the public surface of aowl.api, one example per class, route map, compatibility rule
  Aowl.Api/                      [BepInPlugin("aowl.api", "Aowl API", "0.1.0")] -- the library every consumer depends on
    AowlApi.cs                   config ([Backend] Url/Enabled/PollWaitMs, [Sidecar]), startup, main-thread queue, status line
    AowlHttp.cs                  one HttpClient; three outcomes (transport error / status / JSON)      (was Basement.Client/Http.cs)
    AowlBackend.cs               sidecar start, GET /status, version check, WaitReady, EnsureWorld    (was Sidecar.cs)
    Link.cs + AowlEvents.cs      long poll, persisted cursor, hole/restart detection, directive REGISTRY, typed events (was Link.cs)
    AowlBrain.cs                 Ask (POST /say -> streamed sentences), Observe, Ack
    AowlSpeech.cs                Say (wav at a transform/position/2-D, clip cache), Listen (push-to-talk -> /speech/chunk), PushToTalk (/speech/ptt)
    AowlWorld.cs                 typed people / person / scene / loot / caches / spawn queries
    Pcm.cs                       the 16 kHz resampler (ChunkCheck links this file)                     (was Basement.Client/Pcm.cs)
  Basement.Client/               [BepInPlugin("aowl.basement", ...)] [BepInDependency("aowl.api")] -- the game-facing consumer
    Plugin.cs                    config ([Backend] Enabled/Preset/NoticeM, [Voice], [Raid], [Debug]), handler registration, startup on top of the API
    People.cs                    personId -> live bot map (nickname HEURISTIC + proximity FALLBACK) over AowlWorld.People
    Say.cs                       say segments: per-person queue, seq order, no wait for final, wav -> AudioClip, spatial at the bot or 2-D
    See.cs                       facts: raid_started/ended, tick, player_moved, player_seen/lost, player_aimed_at, player_lowered_weapon, player_fired, player_hit, player_died, npc_died
    Hear.cs                      talk key + in-process microphone -> AowlSpeech.Listen; backend-recorder fallback via AowlSpeech.PushToTalk
    Spawn.cs                     MenuScreen.Show postfix -> AowlWorld.Spawn -> log the map; AutoRaidStart=true actually starts the offline raid
    Mute.cs                      BotTalk.Say prefix: vanilla bot voice lines dropped
    Hud.cs                       IMGUI subtitles / notes
  Examples/HelloAowl/            a 60-line third-party-style consumer: F9 asks the nearest person its name and plays the reply
  ChunkCheck/                    offline proof of the speech-in path (resampler self-check + a real stream to /speech/chunk)
  MemberCheck/                   the offline verifier (dotnet, Mono.Cecil from BepInEx\core)
```

## Build

```
dotnet build mods/basement/spt/Aowl.sln -c Release -p:OutDir=<somewhere>\
    -> Aowl.Api.dll + Aowl.Api.xml + Basement.Client.dll + HelloAowl.dll     (never touches D:\SPT415)
dotnet build mods/basement/spt/Aowl.sln -c Release
    -> D:\SPT415\BepInEx\plugins\                                            (the csproj default OutDir, like FOVFix)
```

`SPT_INSTALL_DIR` or `-p:SptInstallDir=` overrides `D:\SPT415`. Needs `dotnet`
(10.0.400 at `C:\Program Files\dotnet`) and the BepInEx feed in `NuGet.Config`.
Both `Aowl.Api.dll` and `Basement.Client.dll` go in `BepInEx\plugins`; the
basement plugin refuses to load without `aowl.api` (hard dependency).

MEASURED 2026-09-07 (`Aowl.sln`, `-p:OutDir=<scratchpad>\sptbuild\`):

```
Build succeeded.
    0 Warning(s)
    0 Error(s)
```

Two compile facts worth keeping: Assembly-CSharp declares a **global `Paths`
type** that shadows `BepInEx.Paths` (write `BepInEx.Paths.ConfigPath`), and
`FontStyle` needs `UnityEngine.TextRenderingModule.dll`. A third from the
split: `EFT.SpawnInfo` exists, so the API's record is `SpawnPlace`.

## The sidecar root

`[Sidecar] SidecarRoot` (default `BepInEx\plugins\aowlspt-sidecar\`) must look
like this -- the shape `tools/basement_twomod.py::stage` uses, minus tarkov:

```
aowlspt-sidecar\
  aowlspt-backend.exe                    copy of backend\bin\aowlspt-backend.exe
  mods\
    aowlspt-selection.json               {"schema":"aowlspt.selection/1","side":"server",
                                          "registry":"<abs path>\\registry\\mods.json","load":["aowl.basement"]}
    basement\
      basement.dll                       copy of mods\basement\bin\basement.dll
      config.json                        mods\basement\config.json with "enabled": true
      data\                              mods\basement\data (without data\cache)
  registry\
    mods.json                            {"schema":"aowlspt.registry/1","registry":{"id":"bare","name":"basement bare","revision":1},
                                          "mods":[{"id":"aowl.basement","name":"Escape From My Basement","author":"savannt",
                                                   "version":"0.1.0","sides":["server"],"provides":[]}]}
```

**MEASURED 2026-09-06 -- basement loads on a bare root with NO `mods/tarkov`
and NO `db.json`.** A root of exactly that shape was staged in the scratchpad
and `aowlspt-backend.exe --root <root> --port 6975 --no-store-lock` answered
`GET /aowlspt/basement/status` **HTTP 200 in 0.5 s** with
`"ok":true,"mod":"aowl.basement","enabled":true`. The only degradation it
reported: `items: no templates.items on this host (the db read was refused)
-- ... INCONCLUSIVE`, i.e. item-name resolution needs a `db.json` in the root;
everything else (names, archetypes, intents, presets, builtin llm) loaded.
(`sttEngine`/`ttsEngine` were `none` for that run; with whisper/piper the
engine probes report their own paths on `/status`.)

`ANTHROPIC_API_KEY` reaches the backend from the **environment of the process
that starts it** (the game, when the plugin auto-starts the sidecar). There is
no key in this plugin, its config, or this repo.

## Config

`BepInEx\config\aowl.api.cfg` (the library; see API.md):

| key | default | meaning |
|---|---|---|
| Backend.Url | `http://127.0.0.1:6970` | sidecar base URL |
| Backend.Enabled | `false` | master switch; off = one log line, nothing else |
| Backend.PollWaitMs | `20000` | `/events` hold time (backend clamps at 25000) |
| Sidecar.AutoStart / SidecarExe / SidecarRoot / SidecarPort | see above | |

`BepInEx\config\aowl.basement.cfg` (this plugin):

| key | default | meaning |
|---|---|---|
| Backend.Enabled | `false` | master switch for the basement client |
| Backend.Preset | `` | `POST /world/new {preset}` when there is no world |
| Backend.NoticeM | `25` | fallback; `/status encounters.noticeM` wins |
| Voice.PushToTalkKey | `V` | hold to talk |
| Voice.TalkNeedsAddressee | `true` | contract 6.5: no addressee = no session |
| Voice.MatchPeopleByName / BindUnmatchedBots | `true` | HEURISTIC nickname mapping / proximity FALLBACK |
| Voice.CaptureInProcess / MicDevice / ChunkMs | `true` / `` / `250` | in-process microphone -> /speech/chunk |
| Voice.MuteVanillaVoice | `true` | drop vanilla bot voice lines |
| Raid.SpawnOnMenu | `true` | `GET /spawn` on the menu and log the map |
| Raid.AutoRaidStart | `false` | actually start that raid from code |

## Verified vs stubbed

"Verified" = the member exists with that signature in Assembly-CSharp 4.1.5
(MemberCheck, 2026-09-06). It does NOT mean the behaviour was seen live.

| contract item | implementation | members (all PRESENT) |
|---|---|---|
| raid_started / raid_ended | `Singleton<GameWorld>.Instantiated`, `GameWorld.MainPlayer`, `GameWorld.LocationId` transitions; reason from a Harmony prefix on `TarkovApplication.ShowSessionResult(..., ExitStatus exitStatus, ...)` (Survived/Transit=extract, Killed=death, else disconnect) | `Comfort.Common.Singleton<T>.Instance/Instantiated`, `EFT.GameWorld.MainPlayer` (field), `LocationId`, `EFT.ExitStatus` |
| tick | 1 Hz | -- |
| player_moved | every 2 s + once at raid start; yaw = `Player.Rotation.x` | `EFT.Player.Position`, `Rotation` (Vector2) |
| player_seen / player_lost | mapped bots alive (`GameWorld.AllAlivePlayersList`), within noticeM, inside 35 deg of `Player.CameraPosition.forward`; ties: distance, angle, id | `AllAlivePlayersList` (List<Player> field), `CameraPosition` (Transform), `LookDirection` |
| player_aimed_at / player_lowered_weapon | `Player.HandsController.IsAiming` held 400 ms / clear 1 s | `EFT.Player.AbstractHandsController.IsAiming` |
| player_fired | `Player.FirearmController.OnShot` (Action); **`hit` is unknown -> sent `false` with `hitKnown:false`** | `FirearmController.OnShot` |
| player_hit | `ActiveHealthController.ApplyDamageEvent(EBodyPart, float, DamageInfo)`; attacker via `DamageInfo.Player.iPlayer.ProfileId`; **hp = `IHealthController.HealthRate`, semantics UNVERIFIED (payload says so in `hpSource`)** -- `GetBodyPartHealth` does NOT exist on `IHealthController` in 4.1.5 | `ApplyDamageEvent`, `EFT.Ballistics.DamageInfo.Player`, `IObserverToPlayerBridge.iPlayer`, `HealthRate` |
| player_died / npc_died | `Player.OnPlayerDead(Player, IPlayer lastAggressor, DamageInfo, EBodyPart)` on the main player and every mapped bot | `EFT.OnPlayerDead.Invoke` |
| say | wav read from the path (same machine), RIFF chunk scan, `AudioClip.Create`, `AudioSource` on the bot's GameObject (`spatialBlend 1`, linear rolloff 40 m) or a 2-D source when unmapped; paced by `AudioSource.isPlaying` | `EFT.Player : MonoBehaviour` |
| push-to-talk | `Input.GetKeyDown/GetKey/GetKeyUp`, GUID session, `POST /speech/ptt {session,state,personId}` | -- |
| player.spawn / always in raid | postfix on `MenuScreen.Show(Profile, MatchmakerPlayersController, ESessionMode)` -> `GET /spawn` (the map is under **`spawn.map`** -- note `bridge/spawn.nim` reads a top-level `map`, which `basement.nim::onSpawn` does not emit); with `AutoRaidStart`: `TarkovApplication.Exist(out app)`, `_raidSettings` (refused if null), `Session.LocationSettings.locations[map]` by key/Id/Name, set `SelectedLocation/Side=Pmc/RaidMode=Local/IsPveOffline`, invoke `OnReadyToStartMatchingAsync()` -- the method the Ready button ends in; it reads `_raidSettings`, `StoreProfile()`s the menu operation and calls `LocalGameMatching` when `RaidSettings.Local` | all listed, plus `EFT.ESideType`, `ERaidMode`, `JsonType.LocationSettings.Location.Id/Name` |

**No `MainMenuController` type exists in 4.1.5** (grep: none); the controllers
are `MenuScreen/MainMenuScreenController` etc. and the raid entry is on
`TarkovApplication`. Skipping the offline-raid screen also skips SPT's
`SetPreRaidSettingsScreenDefaultsPatch` (`spt-custom.dll`), so `BotSettings`
/`WavesSettings` are whatever `_raidSettings` holds -- untested.

### Stubbed / refused (acked `ok:false` with the reason, never ignored)

* `npc.stance/follow/hold/goto/attack` -- no bot actuator wired.
* `npc.give/take`, `player.captive/release` -- no inventory or leash code.
* `group.spawn` -- does not drive SPT's `BotSpawner`. Instead `MatchPeopleByName`
  binds a backend person to a live bot whose `Profile.Info.Nickname` equals
  the person's name (logged as HEURISTIC on every bind). Without it nothing is
  addressable and `player_seen` never fires.
* `/speech/chunk` -- not used; the backend records on this machine via
  `/speech/ptt` (the SPT side of that route is the same shape).

## Verification that can fail (from PORT-SPT415.md)

1. plugin loaded: `BepInEx\LogOutput.log` has `aowl.basement` and
   `basement: startup complete` (or the exact refusal: `GET /status failed`,
   `enabled:false`, `no world and POST /world/new refused`).
2. facts flow: `GET /aowlspt/basement/status` `observe` counter rises while
   looking at a nickname-mapped bot; negative: flat while looking at nothing.
3. directives flow: `POST /say` from curl -> subtitle + audio within 2 s,
   `pendingAcks` empty.
4. always-in-raid (AutoRaidStart=true): from the menu, the player lands on the
   map `/spawn` named without touching the mouse. **Unproven.**

None of the four has been run: no game was launched for this work.

## Unverified

* Everything at runtime: Harmony patch targets binding, `_raidSettings`
  being non-null at the menu, `CameraPosition` being the actual camera,
  `HealthRate` meaning 0..1 health, `AudioClip.Create` accepting piper's
  22.05 kHz mono output (the decoder passes the file's own rate).
* Whether `Player.Rotation.x` is yaw in degrees (assumed).
