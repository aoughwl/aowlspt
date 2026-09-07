using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// The client half of aowl.basement for SPT 4.1.5, per
    /// mods/basement/CLIENT-CONTRACT.md. The brain lives in aowlspt-backend.exe
    /// running as a SIDECAR on another port; this plugin reports facts,
    /// executes directives, plays wavs and forwards push-to-talk. It holds no
    /// game state the backend needs. NO API key lives here or in its config:
    /// the backend reads ANTHROPIC_API_KEY from the sidecar process environment.
    /// </summary>
    [BepInPlugin("aowl.basement", "Escape From My Basement", "0.1.0")]
    public sealed class Plugin : BaseUnityPlugin
    {
        internal static ManualLogSource Log;
        internal static Plugin Instance;

        // ---- config (BepInEx\config\aowl.basement.cfg) ----
        internal static ConfigEntry<string> BackendUrl;
        internal static ConfigEntry<bool> Enabled;
        internal static ConfigEntry<int> PollWaitMs;
        internal static ConfigEntry<KeyCode> PushToTalkKey;
        internal static ConfigEntry<bool> SpawnOnMenu;
        internal static ConfigEntry<bool> AutoRaidStart;
        internal static ConfigEntry<string> SidecarExe;
        internal static ConfigEntry<string> SidecarRoot;
        internal static ConfigEntry<int> SidecarPort;
        internal static ConfigEntry<bool> SidecarAutoStart;
        internal static ConfigEntry<string> Preset;
        internal static ConfigEntry<float> NoticeM;
        internal static ConfigEntry<bool> MatchPeopleByName;
        internal static ConfigEntry<bool> BindUnmatchedBots;
        internal static ConfigEntry<bool> TalkNeedsAddressee;

        // ---- the main-thread queue: background threads enqueue, Update() drains ----
        private static readonly ConcurrentQueue<Action> MainQueue = new ConcurrentQueue<Action>();
        internal static void OnMain(Action a) { if (a != null) MainQueue.Enqueue(a); }

        internal static readonly Link Link = new Link();
        internal static bool Started;            // the section-8 startup sequence finished
        internal static string StartupNote = "not started";

        private static readonly HashSet<string> Said = new HashSet<string>();
        /// <summary>True the first time a tag is seen. Keeps a repeating refusal out of the log.</summary>
        internal static bool Once(string tag) { lock (Said) return Said.Add(tag); }

        private void Awake()
        {
            Log = Logger;
            Instance = this;
            var pluginDir = Path.GetDirectoryName(Info.Location) ?? BepInEx.Paths.PluginPath;

            BackendUrl = Config.Bind("Backend", "BackendUrl", "http://127.0.0.1:6970",
                "Base URL of the aowlspt-backend sidecar serving /aowlspt/basement/*.");
            Enabled = Config.Bind("Backend", "Enabled", false,
                "Master switch. OFF by default: with it off the plugin loads, logs one line, and does nothing.");
            PollWaitMs = Config.Bind("Backend", "PollWaitMs", 20000,
                "Long-poll hold time for GET /events (the backend clamps to 25000).");
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
            BindUnmatchedBots = Config.Bind("Voice", "BindUnmatchedBots", true,
                "FALLBACK binding: a live bot with no nickname match becomes the nearest unbound world person on this map (else any unbound person, logged as relocated). Without it, ordinary SPT bots (random nicknames) are never addressable and nobody talks.");

            SpawnOnMenu = Config.Bind("Raid", "SpawnOnMenu", true,
                "On the main menu, GET /spawn and log the map the world wants the player on.");
            AutoRaidStart = Config.Bind("Raid", "AutoRaidStart", false,
                "ACTUALLY start the offline raid on that map from code (TarkovApplication._raidSettings + OnReadyToStartMatchingAsync). Members verified against Assembly-CSharp 4.1.5 offline; never yet executed in a live client -- default OFF.");

            SidecarAutoStart = Config.Bind("Sidecar", "AutoStart", true,
                "If GET /status does not answer within 2 s, start the sidecar backend.");
            SidecarExe = Config.Bind("Sidecar", "SidecarExe", Path.Combine(pluginDir, "aowlspt-sidecar", "aowlspt-backend.exe"),
                "Path to aowlspt-backend.exe.");
            SidecarRoot = Config.Bind("Sidecar", "SidecarRoot", Path.Combine(pluginDir, "aowlspt-sidecar"),
                "Root passed as --root: must hold mods\\basement\\basement.dll, mods\\aowlspt-selection.json and registry\\mods.json (see README).");
            SidecarPort = Config.Bind("Sidecar", "SidecarPort", 6970, "Port passed as --port.");

            Http.BaseUrl = BackendUrl.Value;

            if (!Enabled.Value)
            {
                Log.LogWarning("aowl.basement is loaded but Enabled=false in BepInEx/config/aowl.basement.cfg -- doing nothing.");
                StartupNote = "Enabled=false";
                return;
            }

            Spawn.Install();
            var t = new Thread(StartupThread) { IsBackground = true, Name = "basement-startup" };
            t.Start();
        }

        /// <summary>CLIENT-CONTRACT section 8, in order, off the main thread.</summary>
        private static void StartupThread()
        {
            try
            {
                if (SidecarAutoStart.Value) Sidecar.Ensure();

                // 1. GET /status
                var st = Http.Get(Http.Route("/status"), 5000);
                if (!st.Ok)
                {
                    StartupNote = "GET /status failed: " + st.Err;
                    Log.LogError("basement: " + StartupNote + " -- the link is NOT started. Is the sidecar running on " + Http.BaseUrl + "?");
                    return;
                }
                if (!(st.Json.Value<bool?>("enabled") ?? false))
                {
                    StartupNote = "backend answered enabled:false (mods/basement/config.json `enabled`)";
                    Log.LogWarning("basement: " + StartupNote + " -- doing nothing, as the contract says.");
                    return;
                }
                var enc = st.Json["encounters"] as JObject;
                var notice = enc?.Value<float?>("noticeM");
                See.NoticeM = (notice.HasValue && notice.Value > 0) ? notice.Value : NoticeM.Value;

                // 2. GET /world, else POST /world/new
                var w = Http.Get(Http.Route("/world"), 5000);
                if (!w.Ok)
                {
                    var body = new JObject();
                    if (!string.IsNullOrEmpty(Preset.Value)) body["preset"] = Preset.Value;
                    var nw = Http.Post(Http.Route("/world/new"), body.ToString(), 60000);
                    if (!nw.Ok)
                    {
                        StartupNote = "no world and POST /world/new refused: " + nw.Err;
                        Log.LogError("basement: " + StartupNote);
                        return;
                    }
                    Log.LogInfo("basement: created a new world -- " + (nw.Json.Value<string>("note") ?? ""));
                }

                // 3. people; 4. cursor (inside Link.Start); 5./6. raid_started + tick are See's job.
                People.RefreshSync(null);
                Link.Start();
                Started = true;
                StartupNote = "ok";
                Log.LogInfo("basement: startup complete; noticeM=" + See.NoticeM + ", polling " + Http.Route("/events"));
            }
            catch (Exception ex)
            {
                StartupNote = "startup threw " + ex.GetType().Name + ": " + ex.Message;
                Log.LogError("basement: " + StartupNote);
            }
        }

        private void Update()
        {
            while (MainQueue.TryDequeue(out var a))
            {
                try { a(); }
                catch (Exception ex) { Log.LogError("basement: main-thread action threw " + ex); }
            }
            if (!Enabled.Value) return;
            try { See.Tick(); } catch (Exception ex) { if (Once("see-throw:" + ex.Message)) Log.LogError("basement see: " + ex); }
            try { Hear.Tick(); } catch (Exception ex) { if (Once("hear-throw:" + ex.Message)) Log.LogError("basement hear: " + ex); }
            try { Say.Tick(); } catch (Exception ex) { if (Once("say-throw:" + ex.Message)) Log.LogError("basement say: " + ex); }
            try { Spawn.Tick(); } catch (Exception ex) { if (Once("spawn-throw:" + ex.Message)) Log.LogError("basement spawn: " + ex); }
        }

        private void OnGUI()
        {
            if (!Enabled.Value) return;
            Hud.Draw();
        }

        private void OnApplicationQuit()
        {
            Link.Stop();
            Sidecar.StopIfOurs();
        }
    }
}
