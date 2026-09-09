using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Newtonsoft.Json.Linq;

namespace Aowl.Api
{
    /// <summary>
    /// The backend process and its health: sidecar discovery/start, the base
    /// URL, GET /status, and the version compatibility check.
    ///
    /// The sidecar launcher: if GET /aowlspt/basement/status does not answer
    /// within 2 s, start `aowlspt-backend.exe --root SidecarRoot --port
    /// SidecarPort --no-store-lock` -- never more than one: a process of that
    /// name already alive is left alone and reported. The child inherits this
    /// process environment, which is where ANTHROPIC_API_KEY comes from; this
    /// plugin never reads or writes it.
    /// </summary>
    public static class AowlBackend
    {
        /// <summary>Where the API's startup got to.</summary>
        public enum BackendState
        {
            /// <summary>Awake has not run yet.</summary>
            Unknown,
            /// <summary><c>[Backend] Enabled=false</c>: nothing will ever start.</summary>
            Disabled,
            /// <summary>The startup thread is running (sidecar, /status, link).</summary>
            Starting,
            /// <summary>/status answered ok and enabled, the long poll is running.</summary>
            Ready,
            /// <summary>Startup gave up; <see cref="Note"/> says why.</summary>
            Failed,
        }

        /// <summary>The backend versions this API was written against. Older = a feature may be missing; newer = a field may have moved.</summary>
        public const string BackendMinVersion = "0.1.0";
        /// <summary>The newest backend version this API has been checked against.</summary>
        public const string BackendMaxKnownVersion = "0.1.0";
        /// <summary>The <c>schema</c> prefix /status must carry.</summary>
        public const string StatusSchemaPrefix = "aowlspt.basement.status/";

        /// <summary>The current startup state.</summary>
        public static BackendState State { get; private set; } = BackendState.Unknown;
        /// <summary>One line explaining <see cref="State"/> ("ok", or the exact refusal).</summary>
        public static string Note { get; private set; } = "not started";
        /// <summary>The backend's <c>version</c> from /status ("" until probed).</summary>
        public static string BackendVersion { get; private set; } = "";
        /// <summary>The backend's <c>enabled</c> from /status.</summary>
        public static bool BackendEnabled { get; private set; }
        /// <summary>The verdict of the version check: "compatible", "backend OLDER than ...", "backend NEWER than ...", or "unknown".</summary>
        public static string Compatibility { get; private set; } = "unknown";
        /// <summary>The last /status JSON (null until probed). Read-only for callers; it is replaced, never mutated.</summary>
        public static JObject LastStatus { get; private set; }
        /// <summary>What the sidecar launcher last did.</summary>
        public static string SidecarNote { get; private set; } = "not checked";

        /// <summary>Fired on the MAIN thread when the state changes (Ready or Failed included).</summary>
        public static event Action<BackendState> StateChanged;

        private static readonly ManualResetEventSlim ReadyGate = new ManualResetEventSlim(false);
        private static Process _ours;

        /// <summary>The backend base URL (from <c>[Backend] Url</c>).</summary>
        public static string BaseUrl => AowlHttp.BaseUrl;
        /// <summary>Absolute URL of a backend route, e.g. <c>Route("/status")</c>.</summary>
        public static string Route(string path) => AowlHttp.Route(path);
        /// <summary>True once the long poll is running.</summary>
        public static bool IsReady => State == BackendState.Ready;

        internal static void SetState(BackendState s, string note)
        {
            State = s; Note = note ?? "";
            if (s == BackendState.Ready || s == BackendState.Failed || s == BackendState.Disabled) ReadyGate.Set();
            var h = StateChanged;
            if (h != null) AowlApi.OnMain(() => h(s));
        }

        /// <summary>
        /// Block a BACKGROUND thread until startup reaches Ready, Failed or
        /// Disabled, or the timeout passes. Returns true only for Ready. Never
        /// call from the main thread: the startup thread posts to it.
        /// </summary>
        public static bool WaitReady(int timeoutMs)
        {
            if (State == BackendState.Ready) return true;
            ReadyGate.Wait(Math.Max(0, timeoutMs));
            return State == BackendState.Ready;
        }

        /// <summary>Run <paramref name="a"/> on the main thread once the backend is Ready; at once if it already is. Never runs on Failed/Disabled.</summary>
        public static void WhenReady(Action a)
        {
            if (a == null) return;
            if (State == BackendState.Ready) { AowlApi.OnMain(a); return; }
            Action<BackendState> once = null;
            once = s => { if (s == BackendState.Ready) { StateChanged -= once; a(); } };
            StateChanged += once;
        }

        /// <summary>
        /// GET /status (background thread), record version/enabled, run the
        /// compatibility check and log its verdict once. False with the reason
        /// when the route does not answer ok.
        /// </summary>
        public static bool Probe(out string why)
        {
            why = null;
            var st = AowlHttp.Get(AowlHttp.Route("/status"), 5000);
            if (!st.Ok) { why = "GET /status failed: " + st.Err; return false; }
            LastStatus = st.Json;
            BackendEnabled = st.Json.Value<bool?>("enabled") ?? false;
            BackendVersion = st.Json.Value<string>("version") ?? "";
            var schema = st.Json.Value<string>("schema") ?? "";
            Compatibility = Compare(BackendVersion, schema);
            if (AowlApi.Once("compat:" + Compatibility))
            {
                var line = "aowl.api " + AowlApi.Version + " against backend " + (BackendVersion.Length > 0 ? BackendVersion : "(no version field)") +
                           " schema " + (schema.Length > 0 ? schema : "(none)") + ": " + Compatibility;
                if (Compatibility == "compatible") AowlApi.Log.LogInfo(line);
                else AowlApi.Log.LogWarning(line + ". Routes and fields this API expects may be missing or moved; each call still reports its own refusal.");
            }
            return true;
        }

        /// <summary>Re-probe /status now (background thread). The typed answer is in <see cref="LastStatus"/>.</summary>
        public static AowlHttp.Reply Health(int timeoutMs = 5000)
        {
            var r = AowlHttp.Get(AowlHttp.Route("/status"), timeoutMs);
            if (r.Ok) { LastStatus = r.Json; BackendEnabled = r.Json.Value<bool?>("enabled") ?? false; }
            return r;
        }

        /// <summary>
        /// The compatibility rule (API.md): the backend's <c>version</c> must be
        /// between <see cref="BackendMinVersion"/> and <see cref="BackendMaxKnownVersion"/>
        /// inclusive and its <c>schema</c> must start with <see cref="StatusSchemaPrefix"/>.
        /// Outside the range the API still runs; the verdict names which side.
        /// </summary>
        public static string Compare(string backendVersion, string schema)
        {
            if (string.IsNullOrEmpty(backendVersion)) return "unknown (no version on /status)";
            if (!string.IsNullOrEmpty(schema) && !schema.StartsWith(StatusSchemaPrefix, StringComparison.Ordinal))
                return "schema mismatch (" + schema + " is not " + StatusSchemaPrefix + "*)";
            int[] b = Parse(backendVersion), lo = Parse(BackendMinVersion), hi = Parse(BackendMaxKnownVersion);
            if (b == null) return "unknown (unparseable version '" + backendVersion + "')";
            if (Cmp(b, lo) < 0) return "backend OLDER than the minimum " + BackendMinVersion;
            if (Cmp(b, hi) > 0) return "backend NEWER than the newest checked " + BackendMaxKnownVersion;
            return "compatible";
        }

        private static int[] Parse(string v)
        {
            var parts = v.Split('.');
            if (parts.Length < 2) return null;
            var o = new int[3];
            for (int i = 0; i < 3; i++)
            {
                if (i >= parts.Length) { o[i] = 0; continue; }
                var p = parts[i]; int end = 0;
                while (end < p.Length && char.IsDigit(p[end])) end++;
                if (end == 0 || !int.TryParse(p.Substring(0, end), out o[i])) return null;
            }
            return o;
        }
        private static int Cmp(int[] a, int[] b) { for (int i = 0; i < 3; i++) if (a[i] != b[i]) return a[i].CompareTo(b[i]); return 0; }

        /// <summary>
        /// GET /world; when there is none, POST /world/new {preset}. Background
        /// thread. Returns false with the reason when the world cannot be had.
        /// The world is the basement mod's; the API offers this because every
        /// brain call needs one.
        /// </summary>
        public static bool EnsureWorld(string preset, out string note)
        {
            note = "";
            var w = AowlHttp.Get(AowlHttp.Route("/world"), 5000);
            if (w.Ok) { note = "world present: " + (w.Json.Value<string>("name") ?? ""); return true; }
            var body = new JObject();
            if (!string.IsNullOrEmpty(preset)) body["preset"] = preset;
            var nw = AowlHttp.Post(AowlHttp.Route("/world/new"), body.ToString(Newtonsoft.Json.Formatting.None), 60000);
            if (!nw.Ok) { note = "no world and POST /world/new refused: " + nw.Err; return false; }
            note = "created a new world -- " + (nw.Json.Value<string>("note") ?? "");
            return true;
        }

        // ------------------------------------------------------------ the sidecar (lifted from Basement.Client/Sidecar.cs)

        /// <summary>Background thread. Blocks until status answers or the wait is exhausted. Idempotent: never starts a second backend.</summary>
        public static void EnsureSidecar()
        {
            var probe = AowlHttp.Get(AowlHttp.Route("/status"), 2000);
            if (probe.Error == null && probe.Status == 200)
            {
                SidecarNote = "already answering on " + AowlHttp.BaseUrl;
                AowlApi.Log.LogInfo("aowl.api sidecar: " + SidecarNote);
                return;
            }
            var alive = Process.GetProcessesByName("aowlspt-backend");
            if (alive.Length > 0)
            {
                SidecarNote = "a process named aowlspt-backend is already running (pid " + alive[0].Id + ") but /status did not answer on " +
                       AowlHttp.BaseUrl + " within 2 s -- it may be on another port or still starting. Not starting a second one.";
                AowlApi.Log.LogWarning("aowl.api sidecar: " + SidecarNote);
                return;
            }
            var exe = AowlApi.SidecarExe.Value;
            var root = AowlApi.SidecarRoot.Value;
            if (!File.Exists(exe))
            {
                SidecarNote = "SidecarExe not found: " + exe;
                AowlApi.Log.LogError("aowl.api sidecar: " + SidecarNote + " -- copy backend\\bin\\aowlspt-backend.exe there or set [Sidecar] SidecarExe.");
                return;
            }
            if (!Directory.Exists(Path.Combine(root, "mods", "basement")))
            {
                SidecarNote = "SidecarRoot has no mods\\basement: " + root;
                AowlApi.Log.LogError("aowl.api sidecar: " + SidecarNote + " -- see mods/basement/spt/README.md for the root layout.");
                return;
            }
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = "--root \"" + root + "\" --port " + AowlApi.SidecarPort.Value + " --no-store-lock",
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            try
            {
                _ours = Process.Start(psi);
                var logPath = Path.Combine(root, "sidecar.log");
                var log = new StreamWriter(logPath, false) { AutoFlush = true };
                _ours.OutputDataReceived += (s, e) => { if (e.Data != null) lock (log) log.WriteLine(e.Data); };
                _ours.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (log) log.WriteLine(e.Data); };
                _ours.BeginOutputReadLine();
                _ours.BeginErrorReadLine();
                AowlApi.Log.LogInfo("aowl.api sidecar: started pid " + _ours.Id + " (" + psi.FileName + " " + psi.Arguments + "); its output goes to " + logPath);
            }
            catch (Exception ex)
            {
                SidecarNote = "Process.Start failed: " + ex.Message;
                AowlApi.Log.LogError("aowl.api sidecar: " + SidecarNote);
                return;
            }
            // Wait for it, bounded. The bare-root backend answered /status in 0.5 s (MEASURED 2026-09-06).
            var t0 = DateTime.UtcNow;
            while ((DateTime.UtcNow - t0).TotalSeconds < 20)
            {
                if (_ours.HasExited)
                {
                    SidecarNote = "the sidecar exited with code " + _ours.ExitCode + " before answering; read " + Path.Combine(root, "sidecar.log");
                    AowlApi.Log.LogError("aowl.api sidecar: " + SidecarNote);
                    return;
                }
                var r = AowlHttp.Get(AowlHttp.Route("/status"), 1500);
                if (r.Error == null && r.Status == 200) { SidecarNote = "started pid " + _ours.Id + ", answering"; return; }
                Thread.Sleep(500);
            }
            SidecarNote = "started pid " + _ours.Id + " but /status did not answer within 20 s";
            AowlApi.Log.LogWarning("aowl.api sidecar: " + SidecarNote);
        }

        /// <summary>Kill the sidecar only if this process started it.</summary>
        public static void StopSidecarIfOurs()
        {
            try
            {
                if (_ours != null && !_ours.HasExited)
                {
                    AowlApi.Log.LogInfo("aowl.api sidecar: stopping pid " + _ours.Id + " (we started it)");
                    _ours.Kill();
                }
            }
            catch { }
        }
    }
}
