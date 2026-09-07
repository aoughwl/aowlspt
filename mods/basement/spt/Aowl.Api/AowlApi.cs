using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using UnityEngine;

namespace Aowl.Api
{
    /// <summary>
    /// The Aowl API plugin (<c>aowl.api</c>). Other plugins declare
    /// <c>[BepInDependency(AowlApi.Guid)]</c> and then use the static classes:
    /// <see cref="AowlBackend"/> (sidecar, base URL, health, version check),
    /// <see cref="AowlEvents"/> (the event stream and directive registry),
    /// <see cref="AowlBrain"/> (ask / observe), <see cref="AowlSpeech"/>
    /// (play wavs, stream push-to-talk) and <see cref="AowlWorld"/> (typed
    /// people / scene / loot / cache queries).
    ///
    /// The brain lives in <c>aowlspt-backend.exe</c> running as a SIDECAR on
    /// another port; this plugin holds no game state the backend needs and
    /// NO API key: the backend reads ANTHROPIC_API_KEY from the sidecar
    /// process environment.
    ///
    /// Startup (off the main thread): ensure the sidecar, GET /status, check
    /// the version, start the long poll. <see cref="AowlBackend.State"/> says
    /// where it got to and <see cref="AowlBackend.WaitReady"/> blocks a
    /// consumer's own background thread until then.
    /// </summary>
    [BepInPlugin(Guid, Name, Version)]
    public sealed class AowlApi : BaseUnityPlugin
    {
        /// <summary>The BepInEx GUID to depend on: <c>[BepInDependency(AowlApi.Guid)]</c>.</summary>
        public const string Guid = "aowl.api";
        /// <summary>The plugin's display name.</summary>
        public const string Name = "Aowl API";
        /// <summary>This API's version. The backend's own version is <see cref="AowlBackend.BackendVersion"/>.</summary>
        public const string Version = "0.1.0";

        /// <summary>The API's log source (BepInEx console + LogOutput.log).</summary>
        public static ManualLogSource Log;
        /// <summary>The plugin instance; its GameObject hosts the 2-D fallback AudioSource.</summary>
        public static AowlApi Instance;

        // ---- config (BepInEx\config\aowl.api.cfg) ----
        internal static ConfigEntry<string> BackendUrl;
        internal static ConfigEntry<bool> Enabled;
        internal static ConfigEntry<int> PollWaitMs;
        internal static ConfigEntry<string> SidecarExe;
        internal static ConfigEntry<string> SidecarRoot;
        internal static ConfigEntry<int> SidecarPort;
        internal static ConfigEntry<bool> SidecarAutoStart;
        internal static ConfigEntry<int> StatusEveryS;

        // ---- the main-thread queue: background threads enqueue, Update() drains ----
        private static readonly ConcurrentQueue<Action> MainQueue = new ConcurrentQueue<Action>();
        /// <summary>Run <paramref name="a"/> on the Unity main thread during the next Update(). Any thread.</summary>
        public static void OnMain(Action a) { if (a != null) MainQueue.Enqueue(a); }

        /// <summary>Milliseconds since the plugin loaded; any thread (Time.* is main-thread only).</summary>
        private static readonly System.Diagnostics.Stopwatch Clock = System.Diagnostics.Stopwatch.StartNew();
        /// <summary>Milliseconds since the API loaded. Any thread.</summary>
        public static long NowMs => Clock.ElapsedMilliseconds;
        private float _nextStatusAt;

        private static readonly HashSet<string> Said = new HashSet<string>();
        /// <summary>True the first time a tag is seen. Keeps a repeating refusal out of the log. Any thread.</summary>
        public static bool Once(string tag) { lock (Said) return Said.Add(tag); }

        private void Awake()
        {
            Log = Logger;
            Instance = this;
            var pluginDir = Path.GetDirectoryName(Info.Location) ?? BepInEx.Paths.PluginPath;

            BackendUrl = Config.Bind("Backend", "Url", "http://127.0.0.1:6970",
                "Base URL of the aowlspt-backend sidecar serving /aowlspt/basement/*.");
            Enabled = Config.Bind("Backend", "Enabled", false,
                "Master switch. OFF by default: with it off the API loads, logs one line, and every consumer sees AowlBackend.State == Disabled.");
            PollWaitMs = Config.Bind("Backend", "PollWaitMs", 20000,
                "Long-poll hold time for GET /events (the backend clamps to 25000).");
            StatusEveryS = Config.Bind("Backend", "StatusEveryS", 60,
                "Log the API status line (link, speech and brain counters) every N seconds once started. 0 = never.");

            SidecarAutoStart = Config.Bind("Sidecar", "AutoStart", true,
                "If GET /status does not answer within 2 s, start the sidecar backend.");
            SidecarExe = Config.Bind("Sidecar", "SidecarExe", Path.Combine(pluginDir, "aowlspt-sidecar", "aowlspt-backend.exe"),
                "Path to aowlspt-backend.exe.");
            SidecarRoot = Config.Bind("Sidecar", "SidecarRoot", Path.Combine(pluginDir, "aowlspt-sidecar"),
                "Root passed as --root: must hold mods\\basement\\basement.dll, mods\\aowlspt-selection.json and registry\\mods.json (see mods/basement/spt/README.md).");
            SidecarPort = Config.Bind("Sidecar", "SidecarPort", 6970, "Port passed as --port.");

            AowlHttp.BaseUrl = BackendUrl.Value;

            if (!Enabled.Value)
            {
                Log.LogWarning("aowl.api is loaded but Enabled=false in BepInEx/config/aowl.api.cfg -- doing nothing; every consumer will see AowlBackend.State == Disabled.");
                AowlBackend.SetState(AowlBackend.BackendState.Disabled, "Enabled=false");
                return;
            }
            AowlBackend.SetState(AowlBackend.BackendState.Starting, "starting");
            var t = new Thread(StartupThread) { IsBackground = true, Name = "aowl-api-startup" };
            t.Start();
        }

        /// <summary>Sidecar, /status, version check, long poll -- in order, off the main thread.</summary>
        private static void StartupThread()
        {
            try
            {
                if (SidecarAutoStart.Value) AowlBackend.EnsureSidecar();
                string why;
                if (!AowlBackend.Probe(out why))
                {
                    AowlBackend.SetState(AowlBackend.BackendState.Failed, why);
                    Log.LogError("aowl.api: " + why + " -- the link is NOT started. Is the sidecar running on " + AowlHttp.BaseUrl + "?");
                    return;
                }
                if (!AowlBackend.BackendEnabled)
                {
                    AowlBackend.SetState(AowlBackend.BackendState.Failed, "backend answered enabled:false (mods/basement/config.json `enabled`)");
                    Log.LogWarning("aowl.api: " + AowlBackend.Note + " -- doing nothing, as the contract says.");
                    return;
                }
                AowlEvents.Link.Start();
                AowlBackend.SetState(AowlBackend.BackendState.Ready, "ok");
                Log.LogInfo("aowl.api " + Version + ": ready; backend " + AowlBackend.BackendVersion + " (" + AowlBackend.Compatibility + "), polling " + AowlHttp.Route("/events"));
            }
            catch (Exception ex)
            {
                AowlBackend.SetState(AowlBackend.BackendState.Failed, "startup threw " + ex.GetType().Name + ": " + ex.Message);
                Log.LogError("aowl.api: " + AowlBackend.Note);
            }
        }

        private void Update()
        {
            while (MainQueue.TryDequeue(out var a))
            {
                try { a(); }
                catch (Exception ex) { Log.LogError("aowl.api: main-thread action threw " + ex); }
            }
            if (!Enabled.Value) return;
            try { AowlSpeech.Tick(); } catch (Exception ex) { if (Once("speech-throw:" + ex.Message)) Log.LogError("aowl.api speech: " + ex); }
            if (AowlBackend.State == AowlBackend.BackendState.Ready && StatusEveryS.Value > 0 && Time.unscaledTime >= _nextStatusAt)
            {
                _nextStatusAt = Time.unscaledTime + StatusEveryS.Value;
                Log.LogInfo(StatusLine());
            }
        }

        /// <summary>The API status, one line -- the counters every subsystem keeps. Any thread.</summary>
        public static string StatusLine()
        {
            var l = AowlEvents.Link;
            return "aowl.api status: backend=" + AowlBackend.State + " (" + AowlBackend.Note + ") version=" + AowlBackend.BackendVersion + " " + AowlBackend.Compatibility +
                " | link=" + l.State + " cursor=" + l.Cursor + " polls=" + l.Polls + " events=" + l.Events + " directives=" + l.Directives +
                " acks=" + l.Acks + " holes=" + l.Holes + " observed=" + l.Observed + " handlers=" + AowlEvents.Directives.Count +
                " | speech chunksSent=" + AowlSpeech.SttChunksSent + " bytesSent=" + AowlSpeech.SttBytesSent + " chunkFails=" + AowlSpeech.SttChunkFails +
                " played=" + AowlSpeech.Played + " playFailed=" + AowlSpeech.PlayFailed + " clipCache=" + AowlSpeech.ClipCacheCount +
                " | brain asks=" + AowlBrain.Asks + " askFails=" + AowlBrain.AskFails;
        }

        private void OnApplicationQuit()
        {
            AowlEvents.Link.Stop();
            AowlBackend.StopSidecarIfOurs();
        }
    }
}
