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

```
spt/
  NuGet.Config                   nuget.org + https://nuget.bepinex.dev (BepInEx.* are NOT on nuget.org -- MEASURED NU1101)
  Basement.Client/
    Basement.Client.csproj       netstandard2.1, BepInEx.Core 5.*, refs from D:\SPT415 (shape of SPT-FOV-Fix\FOVFix.csproj)
    Plugin.cs                    [BepInPlugin("aowl.basement", "Escape From My Basement", "0.1.0")], config, startup (contract section 8), main-thread queue
    Http.cs                      one HttpClient; three outcomes (transport error / status / JSON)
    Link.cs                      long poll GET /events?since=&wait=&limit=64, persisted cursor, firstSeq hole detection, dispatch, POST /ack, POST /observe
    People.cs                    GET /world/people cache + personId -> live bot map (+ the nickname HEURISTIC)
    Say.cs                       say segments: per-person queue, seq order, no wait for final, wav -> AudioClip, spatial at the bot or 2-D
    See.cs                       facts: raid_started/ended, tick, player_moved, player_seen/lost, player_aimed_at, player_lowered_weapon, player_fired, player_hit, player_died, npc_died
    Hear.cs                      push-to-talk key -> POST /speech/ptt {session, state, personId}
    Sidecar.cs                   starts aowlspt-backend.exe when /status does not answer in 2 s; never a second one
    Spawn.cs                     MenuScreen.Show postfix -> GET /spawn -> log the map; AutoRaidStart=true actually starts the offline raid
    Hud.cs                       IMGUI subtitles / notes
  MemberCheck/                   the offline verifier (dotnet, Mono.Cecil from BepInEx\core)
```

## Build

```
dotnet build mods/basement/spt/Basement.Client/Basement.Client.csproj -c Release
    -> D:\SPT415\BepInEx\plugins\Basement.Client.dll       (the csproj default OutDir, like FOVFix)
dotnet build ... -c Release -p:OutDir=<somewhere else>\    (never touches D:\SPT415)
```

`SPT_INSTALL_DIR` or `-p:SptInstallDir=` overrides `D:\SPT415`. Needs `dotnet`
(10.0.400 at `C:\Program Files\dotnet`) and the BepInEx feed in `NuGet.Config`.

MEASURED 2026-09-06 (`-p:OutDir=<scratchpad>\sptbuild\`):

```
  Basement.Client -> ...\scratchpad\sptbuild\Basement.Client.dll
Build succeeded.
    0 Warning(s)
    0 Error(s)
```

Two compile facts worth keeping: Assembly-CSharp declares a **global `Paths`
type** that shadows `BepInEx.Paths` (write `BepInEx.Paths.ConfigPath`), and
`FontStyle` needs `UnityEngine.TextRenderingModule.dll`.

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

## Config (`BepInEx\config\aowl.basement.cfg`)

| key | default | meaning |
|---|---|---|
| Backend.BackendUrl | `http://127.0.0.1:6970` | sidecar base URL |
| Backend.Enabled | `false` | master switch; off = one log line, nothing else |
| Backend.PollWaitMs | `20000` | `/events` hold time (backend clamps at 25000) |
| Backend.Preset | `` | `POST /world/new {preset}` when there is no world |
| Backend.NoticeM | `25` | fallback; `/status encounters.noticeM` wins |
| Voice.PushToTalkKey | `V` | hold to talk |
| Voice.TalkNeedsAddressee | `true` | contract 6.5: no addressee = no session |
| Voice.MatchPeopleByName | `true` | HEURISTIC person->bot mapping by profile nickname |
| Raid.SpawnOnMenu | `true` | `GET /spawn` on the menu and log the map |
| Raid.AutoRaidStart | `false` | actually start that raid from code |
| Sidecar.AutoStart / SidecarExe / SidecarRoot / SidecarPort | see above | |

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
