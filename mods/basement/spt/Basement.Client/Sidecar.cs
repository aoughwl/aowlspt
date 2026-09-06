using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace Basement.Client
{
    /// <summary>
    /// The sidecar launcher. If GET /aowlspt/basement/status does not answer
    /// within 2 s, start `aowlspt-backend.exe --root SidecarRoot --port
    /// SidecarPort --no-store-lock` -- never more than one: a process of that
    /// name already alive is left alone and reported. The child inherits this
    /// process environment, which is where ANTHROPIC_API_KEY comes from; this
    /// plugin never reads or writes it.
    /// </summary>
    internal static class Sidecar
    {
        private static Process _ours;
        public static string Note = "not checked";

        /// <summary>Background thread. Blocks until status answers or the wait is exhausted.</summary>
        public static void Ensure()
        {
            var probe = Http.Get(Http.Route("/status"), 2000);
            if (probe.Error == null && probe.Status == 200)
            {
                Note = "already answering on " + Http.BaseUrl;
                Plugin.Log.LogInfo("basement sidecar: " + Note);
                return;
            }
            var alive = Process.GetProcessesByName("aowlspt-backend");
            if (alive.Length > 0)
            {
                Note = "a process named aowlspt-backend is already running (pid " + alive[0].Id + ") but /status did not answer on " +
                       Http.BaseUrl + " within 2 s -- it may be on another port or still starting. Not starting a second one.";
                Plugin.Log.LogWarning("basement sidecar: " + Note);
                return;
            }
            var exe = Plugin.SidecarExe.Value;
            var root = Plugin.SidecarRoot.Value;
            if (!File.Exists(exe))
            {
                Note = "SidecarExe not found: " + exe;
                Plugin.Log.LogError("basement sidecar: " + Note + " -- copy backend\\bin\\aowlspt-backend.exe there or set [Sidecar] SidecarExe.");
                return;
            }
            if (!Directory.Exists(Path.Combine(root, "mods", "basement")))
            {
                Note = "SidecarRoot has no mods\\basement: " + root;
                Plugin.Log.LogError("basement sidecar: " + Note + " -- see mods/basement/spt/README.md for the root layout.");
                return;
            }
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = "--root \"" + root + "\" --port " + Plugin.SidecarPort.Value + " --no-store-lock",
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
                Plugin.Log.LogInfo("basement sidecar: started pid " + _ours.Id + " (" + psi.FileName + " " + psi.Arguments + "); its output goes to " + logPath);
            }
            catch (Exception ex)
            {
                Note = "Process.Start failed: " + ex.Message;
                Plugin.Log.LogError("basement sidecar: " + Note);
                return;
            }
            // Wait for it, bounded. The bare-root backend answered /status in 0.5 s (MEASURED 2026-09-06).
            var t0 = DateTime.UtcNow;
            while ((DateTime.UtcNow - t0).TotalSeconds < 20)
            {
                if (_ours.HasExited)
                {
                    Note = "the sidecar exited with code " + _ours.ExitCode + " before answering; read " + Path.Combine(root, "sidecar.log");
                    Plugin.Log.LogError("basement sidecar: " + Note);
                    return;
                }
                var r = Http.Get(Http.Route("/status"), 1500);
                if (r.Error == null && r.Status == 200) { Note = "started pid " + _ours.Id + ", answering"; return; }
                Thread.Sleep(500);
            }
            Note = "started pid " + _ours.Id + " but /status did not answer within 20 s";
            Plugin.Log.LogWarning("basement sidecar: " + Note);
        }

        public static void StopIfOurs()
        {
            try
            {
                if (_ours != null && !_ours.HasExited)
                {
                    Plugin.Log.LogInfo("basement sidecar: stopping pid " + _ours.Id + " (we started it)");
                    _ours.Kill();
                }
            }
            catch { }
        }
    }
}
