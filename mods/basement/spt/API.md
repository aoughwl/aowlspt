# Aowl API (`aowl.api`) -- the SPT 4.1.5 client library for the aowlspt backend

A BepInEx 5 plugin that other plugins depend on. It owns everything that
talks to `aowlspt-backend.exe` (the sidecar): discovery and start, the HTTP
transport, the event stream with its cursor and hole detection, push-to-talk
streaming, wav playback with a clip cache, the brain call and the typed world
queries. A consumer never sends HTTP itself.

```csharp
[BepInDependency(AowlApi.Guid)]          // "aowl.api", hard dependency
public sealed class MyPlugin : BaseUnityPlugin { ... }
```

Reference `Aowl.Api.dll` (`<Private>false</Private>`) and ship yours next to
it in `BepInEx\plugins`. `Aowl.Api.xml` carries the XML docs for IntelliSense.

Status 2026-09-07: **compiles (0 warnings, 0 errors); the split has not yet
run in a live SPT client.** The transport code was lifted from
`Basement.Client` (which had run live) byte-for-byte where it worked; the new
surface (handles, registry, typed records) is unexercised in the game.

## Threads, in one paragraph

Every event, handle callback and directive handler runs on the Unity **main
thread** during the API's `Update()`, in stream order. Methods documented
"background thread" (`AowlWorld.People`, `AowlBackend.WaitReady`,
`AowlBackend.EnsureWorld`, `AowlHttp.Get/Post`) block and must not be called
from `Update()`; each has an `Async` twin or is fire-and-forget. `AowlApi.OnMain(a)`
hops any thread back to the main one.

## Config (`BepInEx\config\aowl.api.cfg`)

| key | default | meaning |
|---|---|---|
| Backend.Url | `http://127.0.0.1:6970` | sidecar base URL; every route is under `/aowlspt/basement/` |
| Backend.Enabled | `false` | master switch; off = one log line, `AowlBackend.State == Disabled` |
| Backend.PollWaitMs | `20000` | `/events` hold time (backend clamps at 25000) |
| Backend.StatusEveryS | `60` | the API's status line period; 0 = never |
| Sidecar.AutoStart / SidecarExe / SidecarRoot / SidecarPort | see README | start `aowlspt-backend.exe` when `/status` is silent for 2 s |

The stream cursor persists in `BepInEx\config\aowl.api.cursor` (the old
`aowl.basement.cursor` is adopted once, so the first run after the split does
not replay the ring).

## The surface

### `AowlApi` -- the plugin

| member | what |
|---|---|
| `Guid` / `Name` / `Version` | `"aowl.api"`, `"Aowl API"`, `"0.1.0"` |
| `OnMain(Action)` | run on the main thread next Update; any thread |
| `NowMs` | ms since load; any thread (`Time.*` is main-thread only) |
| `Once(tag)` | true the first time a tag is seen -- for said-once log lines |
| `Log` | the API's `ManualLogSource` |
| `StatusLine()` | every counter on one line (logged every `StatusEveryS`) |

### `AowlBackend` -- sidecar, base URL, health, version

Routes: `GET /status`, `GET /world`, `POST /world/new`, the sidecar process.

| member | what |
|---|---|
| `State` | `Unknown / Disabled / Starting / Ready / Failed`; `Note` says why |
| `StateChanged` | event, main thread |
| `IsReady`, `WaitReady(ms)` (background), `WhenReady(Action)` | gate your own startup on it |
| `BackendVersion`, `Compatibility`, `LastStatus` | from `/status` |
| `Probe(out why)`, `Health()` | re-read `/status` (background) |
| `EnsureWorld(preset, out note)` | `GET /world`, else `POST /world/new` (background) |
| `EnsureSidecar()`, `StopSidecarIfOurs()`, `SidecarNote` | the launcher; never a second process |
| `BaseUrl`, `Route(path)` | `Route("/status")` -> `http://127.0.0.1:6970/aowlspt/basement/status` |

```csharp
// in a background thread of your own plugin
if (!AowlBackend.WaitReady(90000)) { Logger.LogError("aowl: " + AowlBackend.State + " -- " + AowlBackend.Note); return; }
string note; if (!AowlBackend.EnsureWorld("", out note)) { Logger.LogError(note); return; }
```

**The compatibility rule.** `/status` carries `version` and `schema`. The API
declares `BackendMinVersion` and `BackendMaxKnownVersion` (both `0.1.0` today)
and requires `schema` to start with `aowlspt.basement.status/`. `Compare()`
answers one of: `compatible`, `backend OLDER than the minimum X`, `backend
NEWER than the newest checked Y`, `schema mismatch (...)`, `unknown (...)`.
The verdict is logged once at startup (info when compatible, warning
otherwise) and kept in `AowlBackend.Compatibility`; **the API keeps running
either way** -- each call still reports its own refusal, so an older backend
degrades route by route with a named reason, not by dying at startup. A
consumer that needs a route added after 0.1.0 should read
`AowlBackend.BackendVersion` and refuse with its own line.

### `AowlEvents` -- the stream and the directive registry

Routes: `GET /events?since=&wait=&limit=64` (long poll; one request in flight
by construction), `POST /ack`, `POST /observe`.

| member | what |
|---|---|
| `Directives.Register(kind, handler)` / `Unregister` / `Handles(kind)` / `Kinds` | any plugin owns any kind |
| `OnEvent` | every event (typed `AowlEvent`), before the kind handlers |
| `OnSay(SaySegment)`, `OnHeard(HeardEvent)`, `OnHudNote(text, severity)` | typed conveniences |
| `OnResync(reason)` | **link thread**: the cursor jumped after a hole or a backend restart -- re-read your world state |
| `OnDirectiveDropped(seq, kind, reason)` | the backend gave up waiting for an ack: a bug in some client |
| `Link` | counters (`Polls`, `Events`, `Directives`, `Acks`, `Holes`, `Unsupported`...), `Cursor`, `State` |

`AowlEvent`: `Seq`, `Kind`, `Data` (JObject), `WantsAck`, `TtlMs`,
`Str(name, dflt)`, and **`Ack(ok, note)` -- exactly once** (a second call is
dropped and logged). Rules the dispatcher enforces:

* a directive (`WantsAck`) with **no handler** is acked `ok:false "unsupported
  kind: no plugin registered a handler for ..."`, never ignored;
* a handler that **throws** acks `ok:false "handler threw ..."`;
* several handlers may share a kind; all run, the first ack wins;
* a passive kind with no handler is logged once and ignored;
* when the event carries no `ack` field at all (older backends), the kind
  decides: `say`, `heard.*`, `hud.note`, `world.saved`, `directive.*`,
  `quest.*` are passive, everything else wants an ack.

```csharp
AowlEvents.Directives.Register("npc.goto", e =>
{
    var map = e.Str("map"); float x = e.Data.Value<float?>("x") ?? 0;
    if (!TryOrder(e.Str("personId"), map, x, ...)) { e.Ack(false, "no navmesh at that point"); return; }
    e.Ack(true, "order accepted");           // ack when ACCEPTED, not when it arrives
});
```

### `AowlBrain` -- ask, observe

Routes: `POST /say {person, text}`, `POST /observe {kind, ...}`, `POST /ack`.

| member | what |
|---|---|
| `Ask(personId, text)` -> `AskHandle` | the person's reply; `Sentence(SaySegment)` streams as the backend speaks, `Answered(AskReply)` on the HTTP reply, `Failed(reason)` |
| `Observe(kind, JObject)` | a fact the backend cannot know; fire and forget; unknown kinds are accepted and ignored by the backend |
| `Ack(seq, ok, note)` | for a seq held outside an `AowlEvent` (prefer `AowlEvent.Ack`) |
| `RegisterDirective(kind, handler)` | the same registry as `AowlEvents.Directives` |

```csharp
var ask = AowlBrain.Ask(person.Id, "what is your name");
ask.Sentence += seg => AowlSpeech.Say(new SpeechRequest { Text = seg.Text, Wav = seg.Wav, At = botTransform });
ask.Answered += r => Logger.LogInfo(r.Tier + "/" + r.Engine + " " + r.Ms + " ms: " + r.Text);
ask.Failed   += why => Logger.LogWarning(why);   // "no person 'x'", "no `text`", transport...
```

`Sentence` is fed from the stream's `say` events for that person, starting at
the first `segmentIdx == 0` after the ask (a stale utterance still draining is
skipped) and ending at `final`. The backend also broadcasts the same segments
to every `OnSay` subscriber and `say` handler, so a plugin that plays
everything (Basement.Client) and a plugin that plays only its own ask both work
-- once, if they are not both installed for the same person.

### `AowlSpeech` -- speech out, speech in, the clip cache

Routes: `POST /speech/chunk` (streaming), `POST /speech/ptt` (backend
recorder). Playback needs no route: wav paths are on this machine.

| member | what |
|---|---|
| `Say(SpeechRequest)` -> `SpeechHandle` | play a wav at a `Transform`, a `Position`, or 2-D; `Started`, `Finished` (exact: `AudioSource.isPlaying`), `Failed(reason)` |
| `Say(text, wav, position?, personId)` | shorthand |
| `LoadClip(path, out why)` | wav -> `AudioClip`, cached by path + size + mtime, LRU of `ClipCacheMax` (64); `ClearClipCache()` |
| `Listen(personId)` -> `ListenSession` | push-to-talk: `Push(float[], count, srcRate, final)` resamples to 16 kHz PCM16 with the carry kept across pushes, or `Push(byte[] pcm16k, final)`; `Finish()`; `Partial(text)`, `Final(ListenResult)`, `Failed(reason, wasFinal)` |
| `PushToTalk(session, "down"/"up"/"poll", personId, done)` | the backend-recorder fallback |
| counters | `Played`, `PlayFailed`, `SttChunksSent`, `SttBytesSent`, `SttChunkFails`, `ClipHits/Misses` |

```csharp
var s = AowlSpeech.Listen(addresseeId);          // key down
s.Partial += t => Hud("(hearing) " + t);
s.Final   += r => { if (r.Text.Length == 0) Hud("not transcribed: " + r.Note);   // never "said nothing"
                    else if (r.SpokeTo == null) AowlBrain.Ask(addresseeId, r.Text); };  // older backend: ask yourself
// every ChunkMs while held:   s.Push(samples, n, micRate);
s.Finish();                                       // key up -- ALWAYS, also on cancel
```

`ListenResult.SpokeTo` is **null** when the backend did not hand the transcript
to the brain (then ask yourself), `""` when it tried and nobody was addressed
(`SayNote` says why), else the person it asked -- its segments are already on
the stream.

**No text-only TTS route exists on the backend (0.1.0).** The only synthesis
is a person's reply (`AowlBrain.Ask`), whose segments arrive with the wav
made. A `SpeechRequest` with a `VoiceSpec` but neither `Wav` nor `Clip` is
therefore refused through `Failed` with that sentence -- it is not silently
shown as a subtitle. When that route lands, `Say(text, voiceSpec)` is where
it goes.

### `AowlWorld` -- typed queries

| member | route | returns |
|---|---|---|
| `People(map?, nearX?, nearY?, nearZ?, radius)` / `PeopleAsync` | `GET /world/people` | `Result<List<PersonInfo>>` |
| `Person(id)` / `PersonAsync` | `GET /world/person/<id>` | `Result<PersonInfo>` |
| `Scene(map, x, y, z, radius)` / `SceneAsync` | `GET /world/scene` (**materialises** rumoured caches) | `Result<SceneInfo>` (people, caches, loot) |
| `Loot(map)` / `LootAsync` | `GET /world/loot` | `Result<List<LootInfo>>` |
| `Caches(map)` / `CachesAsync` | `GET /world/caches` | `Result<List<CacheInfo>>` |
| `Spawn()` / `SpawnAsync` | `GET /spawn` | `Result<SpawnPlace>` (`Map == ""` + `Err` when declined) |
| `World()` | `GET /world` | `Result<JObject>` |
| `Nearest(people, x, y, z)` | -- | the nearest alive person |

`Result<T>`: `Ok`, `Value`, `Error` -- a refusal is a string, never an
exception. Every record keeps `Raw` (the JObject) for fields not lifted. Note
the backend spells the faction field `faction` (the contract's `factionId` is
read as a fallback) and parses `near=` as integers.

```csharp
var r = await AowlWorld.PeopleAsync("Woods");
if (!r.Ok) { Logger.LogWarning(r.Error); return; }
var who = AowlWorld.Nearest(r.Value, p.x, p.y, p.z);
```

### `AowlHttp` -- the escape hatch

`Get/Post` (background), `GetAsync/PostAsync`, `Route(path)`, `Reply { Status,
Body, Error, Json, Ok, Err }` -- the three outcomes (transport error / HTTP
status / JSON). For a route the API does not wrap. `Resampler` (Pcm.cs) is
public too; `spt/ChunkCheck` compiles the very same file.

## What moved where (the split, 2026-09-07)

| was in Basement.Client | now | notes |
|---|---|---|
| `Http.cs` | `Aowl.Api/AowlHttp.cs` | public; byte-for-byte |
| `Link.cs` | `Aowl.Api/Link.cs` + `AowlEvents.cs` | loop/cursor/hole/restart byte-for-byte; the `switch` dispatch became the registry |
| `Sidecar.cs` | `Aowl.Api/AowlBackend.cs` | byte-for-byte, plus `/status` version check, `WaitReady`, `EnsureWorld` |
| `Pcm.cs` | `Aowl.Api/Pcm.cs` | unchanged (ChunkCheck links the new path) |
| `Hear.cs` sender thread, `Send`, `AskBrain`, `Post` | `AowlSpeech.Listen/ListenSession`, `AowlBrain.Ask`, `AowlSpeech.PushToTalk` | Hear keeps the key and the microphone |
| `Say.cs` `LoadClip` | `AowlSpeech.LoadClip` (+ cache) | Say.cs itself is untouched: it still plays at the bots with its own copy (agent R owns that file) |
| `People.cs` `GET /world/people` | `AowlWorld.People` | People keeps the bot binding |
| `Spawn.cs` `GET /spawn` | `AowlWorld.Spawn` | Spawn keeps the raid gesture |
| `[Backend] BackendUrl/Enabled/PollWaitMs`, `[Sidecar] *` | `aowl.api.cfg` | `aowl.basement.cfg` keeps `[Backend] Enabled/Preset/NoticeM`, `[Voice]`, `[Raid]`, `[Debug]` |

`Basement.Client` registers its kinds (`say`, `heard.*`, `hud.note`,
`quest.*`, `world.saved`, `player.spawn`) and refuses the ones it cannot run
(`npc.*`, `group.spawn`, `player.captive/release`) with the exact reason, all
through `AowlEvents.Directives`. `Plugin.Link` is a shim so `Say/See/Spawn`
call `Plugin.Link.Ack/Observe` as before.

## Example: `Examples/HelloAowl`

Sixty lines: F9 asks the nearest person "what is your name" through
`AowlBrain.Ask` and plays each sentence through `AowlSpeech.Say`; registers a
`hud.note` handler; logs `AowlBackend.StateChanged`.

## Build

```
dotnet build mods/basement/spt/Aowl.sln -c Release -p:OutDir=<dir>\
   -> <dir>\Aowl.Api.dll  Aowl.Api.xml  Basement.Client.dll  HelloAowl.dll
```

Without `OutDir` every project writes into `D:\SPT415\BepInEx\plugins\`.

## Unverified

* Nothing in this split has run in a live client: BepInEx dependency
  ordering (`aowl.api` Awake before `aowl.basement` Awake), `WaitReady`
  against the real startup timing, the registry's ack path, positional
  playback through the pooled emitters, the clip cache under a raid.
* `AskHandle.Sentence` when two asks to the same person overlap.
* `/status` on a backend newer than 0.1.0 (the check has only seen `0.1.0`).
