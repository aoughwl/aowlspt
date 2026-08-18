// The SPT server mod that hosts every native mod.
//
// From SPT's point of view this is one ordinary server mod. From a native mod's
// point of view it is the whole server. Keeping it to a single supported
// extension point is what lets the native side survive SPT point releases: the
// ABI does not track SPT's internals, this file does, and it is small.

using System.Reflection;
using Aowlspt.Abi;
using SPTarkov.Common.Models.Logging;
using SPTarkov.DI.Annotations;
using SPTarkov.Server.Core.DI;
using SPTarkov.Server.Core.Utils;

namespace Aowlspt.Host.Server;

[Injectable(InjectionType.Singleton)]
public sealed class ModEntry : IOnLoad, IOnUpdate, IDisposable
{
    private readonly ISptLogger<ModEntry> _logger;
    private readonly IServiceProvider _provider;
    private readonly JsonUtil _jsonUtil;

    private ModHost? _host;
    private ServerHostServices? _services;
    private long _lastTickMs;

    // Set once during OnLoad so the router (constructed by DI, possibly before
    // this runs) can find the live services without a DI cycle between them.
    internal static ServerHostServices? Live { get; private set; }

    public ModEntry(ISptLogger<ModEntry> logger, IServiceProvider provider, JsonUtil jsonUtil)
    {
        _logger = logger;
        _provider = provider;
        _jsonUtil = jsonUtil;
    }

    public Task OnLoadAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        _services = new ServerHostServices(_provider, _jsonUtil, WriteLog, DetectSptVersion());
        Live = _services;

        _host = new ModHost(_services);

        var modsRoot = ResolveModsRoot();
        _logger.Info($"[aowlspt] loading native mods from {modsRoot}");

        var count = _host.LoadAll(modsRoot);
        if (count == 0)
        {
            _logger.Info("[aowlspt] no native mods found");
        }
        else
        {
            _host.StartAll();
            _services.DrainScheduled();

            var names = string.Join(", ", _host.Mods.Select(m => m.Descriptor.ToString()));
            _logger.Success($"[aowlspt] {count} native mod(s) online: {names}", null);

            var routes = _services.RouteUrls;
            if (routes.Count > 0)
                _logger.Info($"[aowlspt] serving {routes.Count} mod route(s): {string.Join(", ", routes)}");
        }

        _lastTickMs = Environment.TickCount64;
        return Task.CompletedTask;
    }

    /// <summary>
    /// SPT's periodic tick. Returning true keeps it running.
    ///
    /// This is where native `on_update` and anything a mod queued with
    /// `schedule`/`invoke_main` actually runs — the server has no frame loop, so
    /// this tick is what "the main thread" means server-side.
    /// </summary>
    public Task<bool> OnUpdateAsync(long secondsSinceLastRun, CancellationToken cancellationToken)
    {
        if (_host is null || _services is null) return Task.FromResult(false);

        var now = Environment.TickCount64;
        var elapsed = now - _lastTickMs;
        _lastTickMs = now;

        _host.UpdateAll(elapsed);
        _services.DrainScheduled();
        return Task.FromResult(true);
    }

    /// <summary>Publish a server event to every native mod that subscribed.</summary>
    internal static void Emit(ModHost host, string name, string payload = "") => host.Emit(name, payload);

    private void WriteLog(AowlLogLevel level, string source, string message)
    {
        var line = $"[aowlspt/{source}] {message}";
        switch (level)
        {
            case AowlLogLevel.Trace:
            case AowlLogLevel.Debug: _logger.Debug(line); break;
            case AowlLogLevel.Info: _logger.Info(line); break;
            case AowlLogLevel.Success: _logger.Success(line, null); break;
            case AowlLogLevel.Warn: _logger.Warning(line, null); break;
            default: _logger.Error(line, null); break;
        }
    }

    /// <summary>
    /// Native mods live in `user/mods/aowlspt/<mod>/`, next to this assembly, so
    /// that installing one is still "drop a folder in user/mods" and no part of
    /// the SPT install outside that folder is touched.
    /// </summary>
    private static string ResolveModsRoot()
    {
        var overridePath = Environment.GetEnvironmentVariable("AOWLSPT_MODS");
        if (!string.IsNullOrWhiteSpace(overridePath)) return overridePath!;

        var here = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location)
                   ?? AppContext.BaseDirectory;
        return Path.Combine(here, "mods");
    }

    private static string DetectSptVersion()
    {
        // Read it off SPT's own assembly rather than hard-coding: the value is
        // handed to every mod as `sptVersion()`, and a stale constant there is
        // worse than an empty string.
        foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
        {
            var name = asm.GetName().Name;
            if (name is not ("SPTarkov.Server.Core" or "SPT.Server")) continue;
            var version = asm.GetName().Version;
            if (version is not null) return version.ToString(3);
        }
        return string.Empty;
    }

    public void Dispose()
    {
        _services?.DisposeHarmony();
        _host?.Dispose();
        _host = null;
        Live = null;
    }
}
