// The BepInEx plugin that hosts every native client mod.
//
// Its whole job is to own a ModHost and give it a frame loop. Unity's threading
// rule — touch a GameObject only on the main thread — is the reason
// `invoke_main` exists in the ABI at all, and `Update` here is where that queue
// gets drained.

using System;
using System.IO;
using System.Linq;
using Aowlspt.Abi;
using BepInEx;
using UnityEngine;

namespace Aowlspt.Host.Client;

[BepInPlugin(PluginGuid, "aowlspt host", "1.0.0")]
public sealed class Plugin : BaseUnityPlugin
{
    public const string PluginGuid = "aowl.aowlspt.host";

    private ModHost? _host;
    private ClientHostServices? _services;
    private long _lastTickMs;

    private void Awake()
    {
        try
        {
            _services = new ClientHostServices(WriteLog, DetectGameVersion());
            _host = new ModHost(_services);

            var modsRoot = ResolveModsRoot();
            Logger.LogInfo($"[aowlspt] loading native mods from {modsRoot}");

            var count = _host.LoadAll(modsRoot);
            if (count == 0)
            {
                Logger.LogInfo("[aowlspt] no native client mods found");
                return;
            }

            _host.StartAll();
            _services.DrainScheduled();
            Logger.LogInfo($"[aowlspt] {count} native mod(s) online: " +
                           string.Join(", ", _host.Mods.Select(m => m.Descriptor.ToString()).ToArray()));
        }
        catch (Exception ex)
        {
            // A host that throws in Awake takes the plugin down and, with BepInEx's
            // error handling, can take the game's startup with it. Log and stay
            // dormant instead.
            Logger.LogError($"[aowlspt] host failed to start: {ex}");
            _host = null;
        }
        finally
        {
            _lastTickMs = NowMs();
        }
    }

    private void Update()
    {
        if (_host is null || _services is null) return;

        var now = NowMs();
        var elapsed = now - _lastTickMs;
        _lastTickMs = now;

        _host.UpdateAll(elapsed);

        // Drained after the tick so work queued during this frame's on_update
        // runs on the next frame rather than re-entering mid-tick.
        _services.DrainScheduled();
    }

    private void OnDestroy()
    {
        _services?.DisposeHarmony();
        _host?.Dispose();
        _host = null;
    }

    private static long NowMs() => (long)(Time.realtimeSinceStartup * 1000f);

    private void WriteLog(AowlLogLevel level, string source, string message)
    {
        var line = $"[{source}] {message}";
        switch (level)
        {
            case AowlLogLevel.Trace:
            case AowlLogLevel.Debug: Logger.LogDebug(line); break;
            case AowlLogLevel.Info: Logger.LogInfo(line); break;
            case AowlLogLevel.Success: Logger.LogMessage(line); break;
            case AowlLogLevel.Warn: Logger.LogWarning(line); break;
            default: Logger.LogError(line); break;
        }
    }

    /// <summary>
    /// Native client mods live in `BepInEx/plugins/aowlspt/mods/<mod>/`, beside
    /// this assembly — so installing one stays "drop a folder in", and nothing
    /// outside that folder is touched.
    /// </summary>
    private static string ResolveModsRoot()
    {
        var overridePath = Environment.GetEnvironmentVariable("AOWLSPT_MODS");
        if (!string.IsNullOrEmpty(overridePath)) return overridePath!;

        var here = Path.GetDirectoryName(typeof(Plugin).Assembly.Location) ?? BepInEx.Paths.PluginPath;
        return Path.Combine(here, "mods");
    }

    private static string DetectGameVersion()
    {
        try { return Application.version ?? string.Empty; }
        catch (Exception) { return string.Empty; }
    }
}
