using System;
using System.Collections.Generic;
using System.Threading;
using Aowl.Api;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// The client half of aowl.basement for SPT 4.1.5, per
    /// mods/basement/CLIENT-CONTRACT.md -- now a CONSUMER of the Aowl API
    /// (aowl.api): the sidecar, the HTTP transport, the event stream, the
    /// chunk sender and the world queries live there. This plugin keeps only
    /// the game-facing behaviour: binding backend people to live bots
    /// (People), the facts it can measure (See), playing `say` segments at
    /// the bots (Say), the talk key and microphone (Hear), the raid gesture
    /// (Spawn), the vanilla-voice mute (Mute) and the IMGUI lines (Hud).
    ///
    /// NO API key lives here, in aowl.api, or in either config: the backend
    /// reads ANTHROPIC_API_KEY from the sidecar process environment.
    /// </summary>
    [BepInPlugin("aowl.basement", "Escape From My Basement", "0.1.0")]
    [BepInDependency(AowlApi.Guid, BepInDependency.DependencyFlags.HardDependency)]
    [BepInDependency("xyz.drakia.bigbrain", BepInDependency.DependencyFlags.HardDependency)]   // Orders.cs layer host (measured guid)
    [BepInDependency("me.sol.sain", BepInDependency.DependencyFlags.SoftDependency)]           // load after SAIN so our layer outranks its registration
    public sealed class Plugin : BaseUnityPlugin
    {
        internal static ManualLogSource Log;
        internal static Plugin Instance;

        // ---- config (BepInEx\config\aowl.basement.cfg). [Backend] Url/Enabled/PollWaitMs and [Sidecar] moved to aowl.api.cfg. ----
        internal static ConfigEntry<bool> Enabled;
        internal static ConfigEntry<KeyCode> PushToTalkKey;
        internal static ConfigEntry<bool> SpawnOnMenu;
        internal static ConfigEntry<bool> AutoRaidStart;
        internal static ConfigEntry<string> Preset;
        internal static ConfigEntry<float> NoticeM;
        internal static ConfigEntry<bool> MatchPeopleByName;
        internal static ConfigEntry<bool> MuteVanillaVoice;
        internal static ConfigEntry<bool> BindUnmatchedBots;
        internal static ConfigEntry<bool> TalkNeedsAddressee;
        internal static ConfigEntry<bool> CaptureInProcess;
        internal static ConfigEntry<string> MicDevice;
        internal static ConfigEntry<int> ChunkMs;
        internal static ConfigEntry<int> StatusEveryS;

        /// <summary>Run on the Unity main thread during the next Update(). Any thread. Forwards to the API's queue.</summary>
        internal static void OnMain(Action a) => AowlApi.OnMain(a);

        /// <summary>Milliseconds since the API loaded; any thread (Time.* is main-thread only).</summary>
        internal static long NowMs => AowlApi.NowMs;
        private float _nextStatusAt;

        /// <summary>The stream's Observe/Ack, in the shape Say/See/Spawn call (Plugin.Link.Ack / Plugin.Link.Observe).</summary>
        internal static readonly LinkShim Link = new LinkShim();
        internal static bool Started;            // the section-8 startup sequence finished
        internal static string StartupNote = "not started";

        private static readonly HashSet<string> Said = new HashSet<string>();
        /// <summary>True the first time a tag is seen. Keeps a repeating refusal out of the log.</summary>
        internal static bool Once(string tag) { lock (Said) return Said.Add(tag); }

        private void Awake()
        {
            Log = Logger;
            Instance = this;

            Enabled = Config.Bind("Backend", "Enabled", false,
                "Master switch for the basement client. OFF by default: with it off the plugin loads, logs one line, and does nothing. The backend URL, sidecar and poll settings are in aowl.api.cfg.");
            Preset = Config.Bind("Backend", "Preset", "",
                "World preset for POST /world/new when the backend has no world yet (empty = the backend default).");
            NoticeM = Config.Bind("Backend", "NoticeM", 25f,
                "Fallback notice range in metres; overridden by /status encounters.noticeM when present.");

            PushToTalkKey = Config.Bind("Voice", "PushToTalkKey", KeyCode.V,
                "Hold to talk. Down/up are POSTed to /speech/ptt; the backend records on this machine.");
            TalkNeedsAddressee = Config.Bind("Voice", "TalkNeedsAddressee", true,
                "CLIENT-CONTRACT section 6.5: with nobody alive inside the view cone and notice range, do not open a speech session. Off = post anyway with an empty personId.");
            MatchPeopleByName = Config.Bind("Voice", "MatchPeopleByName", true,
                "HEURISTIC: map a backend person to a live bot whose profile nickname equals the person name. Without group.spawn (no actuator in 0.1.0) it is the only way any bot becomes addressable.");
            MuteVanillaVoice = Config.Bind("Voice", "MuteVanillaVoice", true,
                "Drop every vanilla bot voice line (BotTalk.Say prefix) so the only voices are the world's people. Player VOIP is untouched.");
            CaptureInProcess = Config.Bind("Voice", "CaptureInProcess", true,
                "Capture the microphone IN-PROCESS (UnityEngine.Microphone) while the talk key is held and stream 16 kHz PCM chunks to /speech/chunk, so partial transcripts appear while you speak. Falls back to the backend recorder (/speech/ptt) when no device is available, said once. Off = always the backend recorder.");
            MicDevice = Config.Bind("Voice", "MicDevice", "",
                "Capture device name for in-process capture (one of Microphone.devices, logged at first use). Empty = the default device.");
            ChunkMs = Config.Bind("Voice", "ChunkMs", 250,
                "How often captured audio is read off the microphone ring and posted (CLIENT-CONTRACT section 3 recommends 200-400 ms). Chunks queued behind a slow request are merged, so a partial's whisper pass never drops audio.");
            StatusEveryS = Config.Bind("Debug", "StatusEveryS", 60,
                "Log the bridge status line (people, hear/say counters) every N seconds once started. 0 = never. The link's own line is aowl.api's.");
            BindUnmatchedBots = Config.Bind("Voice", "BindUnmatchedBots", true,
                "FALLBACK binding: a live bot with no nickname match becomes the nearest unbound world person on this map (else any unbound person, logged as relocated). Without it, ordinary SPT bots (random nicknames) are never addressable and nobody talks.");

            // [Subtitles]: preset + per-entry overrides, live-updating (Hud.cs).
            Hud.Bind(Config);

            SpawnOnMenu = Config.Bind("Raid", "SpawnOnMenu", true,
                "On the main menu, GET /spawn and log the map the world wants the player on.");
            AutoRaidStart = Config.Bind("Raid", "AutoRaidStart", false,
                "ACTUALLY start the offline raid on that map from code (TarkovApplication._raidSettings + OnReadyToStartMatchingAsync). Members verified against Assembly-CSharp 4.1.5 offline; never yet executed in a live client -- default OFF.");

            if (!Enabled.Value)
            {
                Log.LogWarning("aowl.basement is loaded but Enabled=false in BepInEx/config/aowl.basement.cfg -- doing nothing.");
                StartupNote = "Enabled=false";
                return;
            }

            RegisterHandlers();
            Spawn.Install();
            Mute.Install();
            var t = new Thread(StartupThread) { IsBackground = true, Name = "basement-startup" };
            t.Start();
        }

        /// <summary>Every event kind this client handles, registered with the API's directive registry (main-thread callbacks).</summary>
        private static void RegisterHandlers()
        {
            AowlEvents.Directives.Register("say", e =>
            {
                var s = SaySegment.From(e);
                // The hearing-aware overload: it reads `audible`/`mode`/
                // `distanceM` off the raw event and DROPS what the player
                // could not have heard. See Say.Enqueue(SaySegment, AowlEvent).
                Say.Enqueue(s, e);
            });
            AowlEvents.Directives.Register("heard.partial", e => Hear.ShowPartial(e.Str("text")));
            AowlEvents.Directives.Register("heard.final", e =>
            {
                var text = e.Str("text");
                var note = e.Str("note");
                Hear.OnHeardFinalEvent(text);
                // An empty final is "not transcribed", never "the player said nothing".
                if (text.Length == 0) Hud.Warn("heard nothing transcribable" + (note.Length > 0 ? " -- " + note : ""));
                else Hud.Note("you: " + text);
                Log.LogInfo("basement heard.final: \"" + text + "\" " + note);
            });
            AowlEvents.Directives.Register("hud.note", e =>
            {
                var text = e.Str("text");
                if (e.Str("severity", "info") == "warn") { Hud.Warn(text); Log.LogWarning("basement HUD: " + text); }
                else { Hud.Note(text); Log.LogInfo("basement HUD: " + text); }
            });
            AowlEvents.Directives.Register("quest.offer", e =>
            {
                Hud.Note("QUEST: " + e.Str("title") + " -- " + e.Str("brief"), 10f);
                Log.LogInfo("basement quest.offer: " + e.Data.ToString(Newtonsoft.Json.Formatting.None));
            });
            AowlEvents.Handler logOnly = e => Log.LogInfo("basement " + e.Kind + ": " + e.Data.ToString(Newtonsoft.Json.Formatting.None));
            AowlEvents.Directives.Register("quest.update", logOnly);
            AowlEvents.Directives.Register("world.saved", logOnly);
            AowlEvents.Directives.Register("player.spawn", e => { if (e.WantsAck) Spawn.OnDirective(e.Seq, e.Data); });
            // The kinds this client KNOWS it cannot run, acked ok:false with the exact reason (never "unsupported kind" alone).
            // npc.goto/hold/follow/attack/stance -> Orders (a BigBrain layer above SAIN's); group.spawn -> GroupSpawn
            // (the client's own BotSpawner). Both are measured-member code that has NOT run live yet; each acks
            // ok:false with the exact reason when it cannot act (docs/SPT415-BOT-CONTROL.md).
            Orders.Install();
            GroupSpawn.Install();
            Refuse("unsupported kind: inventory and captivity are not wired in Basement.Client 0.1.0.",
                "npc.give", "npc.take", "player.captive", "player.release");
            // Re-read the population after a hole or a backend restart (link thread; RefreshSync is a background call).
            AowlEvents.OnResync += reason => People.RefreshSync(null);
        }

        private static void Refuse(string why, params string[] kinds)
        {
            foreach (var kind in kinds)
                AowlEvents.Directives.Register(kind, e =>
                {
                    if (!e.WantsAck) return;
                    if (Once("unsupported:" + e.Kind))
                        Log.LogWarning("basement link: refusing directive kind `" + e.Kind + "` -- " + why + " ACKED ok:false, never ignored.");
                    e.Ack(false, why);
                });
        }

        /// <summary>CLIENT-CONTRACT section 8, in order, off the main thread, on top of the API's own startup.</summary>
        private static void StartupThread()
        {
            try
            {
                // 1. the API's startup: sidecar, GET /status, version check, the long poll.
                if (!AowlBackend.WaitReady(90000))
                {
                    StartupNote = "aowl.api is not ready: " + AowlBackend.State + " -- " + AowlBackend.Note;
                    Log.LogError("basement: " + StartupNote + " -- doing nothing. Check BepInEx/config/aowl.api.cfg and the aowl.api lines above.");
                    return;
                }
                var enc = AowlBackend.LastStatus?["encounters"] as JObject;
                var notice = enc?.Value<float?>("noticeM");
                See.NoticeM = (notice.HasValue && notice.Value > 0) ? notice.Value : NoticeM.Value;

                // 2. GET /world, else POST /world/new
                string wnote;
                if (!AowlBackend.EnsureWorld(Preset.Value, out wnote))
                {
                    StartupNote = wnote;
                    Log.LogError("basement: " + StartupNote);
                    return;
                }
                Log.LogInfo("basement: " + wnote);

                // 3. people; 4. cursor (the API's link); 5./6. raid_started + tick are See's job.
                People.RefreshSync(null);
                Started = true;
                StartupNote = "ok";
                Log.LogInfo("basement: startup complete; noticeM=" + See.NoticeM + ", handling " + AowlEvents.Directives.Count + " event kinds through aowl.api " + AowlApi.Version);
            }
            catch (Exception ex)
            {
                StartupNote = "startup threw " + ex.GetType().Name + ": " + ex.Message;
                Log.LogError("basement: " + StartupNote);
            }
        }

        private void Update()
        {
            if (!Enabled.Value) return;
            try { See.Tick(); } catch (Exception ex) { if (Once("see-throw:" + ex.Message)) Log.LogError("basement see: " + ex); }
            try { Hear.Tick(); } catch (Exception ex) { if (Once("hear-throw:" + ex.Message)) Log.LogError("basement hear: " + ex); }
            try { Say.Tick(); } catch (Exception ex) { if (Once("say-throw:" + ex.Message)) Log.LogError("basement say: " + ex); }
            try { Spawn.Tick(); } catch (Exception ex) { if (Once("spawn-throw:" + ex.Message)) Log.LogError("basement spawn: " + ex); }
            if (Started && StatusEveryS.Value > 0 && Time.unscaledTime >= _nextStatusAt)
            {
                _nextStatusAt = Time.unscaledTime + StatusEveryS.Value;
                Log.LogInfo(StatusLine());
            }
        }

        /// <summary>The bridge status, one line -- the counters every subsystem keeps. Any thread.</summary>
        internal static string StatusLine()
        {
            var l = AowlEvents.Link;
            return "basement status: startup=" + StartupNote +
                " | link=" + l.State + " cursor=" + l.Cursor + " polls=" + l.Polls + " events=" + l.Events + " directives=" + l.Directives +
                " acks=" + l.Acks + " holes=" + l.Holes + " observed=" + l.Observed +
                " | people known=" + People.KnownCount + " mapped=" + People.MappedCount + " binds=" + People.Binds +
                " | hear mode=" + Hear.Mode + " sessions=" + Hear.Sessions + " refused=" + Hear.Refused + " sttChunksSent=" + Hear.SttChunksSent +
                " sttBytesSent=" + Hear.SttBytesSent + " sttChunkFails=" + Hear.SttChunkFails + " partialsShown=" + Hear.PartialsShown +
                " brainAsks=" + Hear.BrainAsks + " micFails=" + Hear.MicFails + " micRate=" + Hear.MicRate + " micWarmupMs=" + Hear.MicWarmupMs +
                " lastFinalMs=" + Hear.LastFinalMs + " mic=" + Hear.MicNote +
                " | say segments=" + Say.Segments + " played=" + Say.Played + " subtitles=" + Say.Subtitles + " failed=" + Say.Failed +
                " flushes=" + Say.Flushes + " gaps=" + Say.Gaps + " sayStartedMs=" + Say.SayStartedMs + " lastLoadMs=" + Say.LastLoadMs;
        }

        private void OnGUI()
        {
            if (!Enabled.Value) return;
            Hud.Draw();
        }
    }

    /// <summary>
    /// The shape Say/See/Spawn already call (<c>Plugin.Link.Ack</c>,
    /// <c>Plugin.Link.Observe</c>), forwarded to the API's stream. Observe
    /// is gated on THIS plugin's startup as before, so no fact leaves before
    /// the world exists.
    /// </summary>
    internal sealed class LinkShim
    {
        public string State => AowlEvents.Link.State;
        public long Cursor => AowlEvents.Link.Cursor;
        /// <summary>POST /observe, fire and forget. Any thread.</summary>
        public void Observe(string kind, JObject fields) { if (Plugin.Started) AowlBrain.Observe(kind, fields); }
        /// <summary>POST /ack for a seq held outside an AowlEvent (Say's queued segments, Spawn's directive).</summary>
        public void Ack(long seq, bool ok, string note) => AowlBrain.Ack(seq, ok, note);
    }
}
