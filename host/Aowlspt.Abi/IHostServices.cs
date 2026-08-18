// What a host has to supply, and nothing more.
//
// ModHost implements everything that is the same everywhere — loading, the ABI
// handshake, the allocator, config, the event bus, hot reload — and asks the
// side it is running on only for the things that genuinely differ: how to log,
// how to reach the SPT database, how to register a route, how to patch a
// method, how to get back onto the main thread.
//
// One implementation exists in .NET: the simulator. (The SPT server host and
// the BepInEx client host implemented this too, and were deleted with the pivot
// to post-1.0; the live client host is native nimony and speaks the C ABI
// directly.) The interface stays side-shaped anyway, because the simulator
// stands in for every side: a capability a side does not have throws
// NotSupportedException, which ModHost turns into AOWLSPT_ERR_UNSUPPORTED for
// the mod, and that is what a mod's `side()` guards are tested against.

using System;

namespace Aowlspt.Abi;

/// <summary>Handles an HTTP request routed to a mod. Returns the response body.</summary>
public delegate string RouteHandler(string url, string body, string session);

/// <summary>
/// Handles a patched host method. <see cref="PatchOutcome.SkipOriginal"/> is
/// only meaningful for a prefix patch.
/// </summary>
public delegate PatchOutcome PatchHandler(string target, string argsJson);

public readonly struct PatchOutcome
{
    public readonly bool SkipOriginal;
    public readonly string? ResultJson;

    public PatchOutcome(bool skipOriginal, string? resultJson)
    {
        SkipOriginal = skipOriginal;
        ResultJson = resultJson;
    }

    public static readonly PatchOutcome Continue = new(false, null);
    public static PatchOutcome Replace(string resultJson) => new(true, resultJson);
}

public interface IHostServices
{
    AowlSide Side { get; }
    string HostName { get; }
    string HostVersion { get; }

    /// <summary>SPT version, or empty where there is no SPT (the simulator).</summary>
    string SptVersion { get; }

    /// <summary>EFT build, or empty server-side.</summary>
    string GameVersion { get; }

    /// <summary><paramref name="source"/> is the mod guid, or the host's own name.</summary>
    void Log(AowlLogLevel level, string source, string message);

    /// <summary>Read the server database at a dotted path. Server side only.</summary>
    string DbGet(string path);

    /// <summary>Merge a JSON patch into the server database. Server side only.</summary>
    void DbPatch(string path, string patchJson);

    /// <summary>Register an HTTP route. Server side only.</summary>
    void RegisterRoute(string url, AowlRouteKind kind, RouteHandler handler);

    /// <summary>Harmony-patch a host method named "Namespace.Type::Method".</summary>
    void RegisterPatch(string target, AowlPatchKind kind, PatchHandler handler);

    /// <summary>Invoke a host member by name. The ABI's escape hatch.</summary>
    string Call(string target, string argsJson);

    /// <summary>Resolve a service or component to a handle.</summary>
    ulong Resolve(string typeName);

    void ReleaseHandle(ulong handle);

    /// <summary>Run <paramref name="action"/> on the main thread after a delay.</summary>
    void Schedule(int delayMs, Action action);

    /// <summary>Run <paramref name="action"/> on the main thread as soon as possible.</summary>
    void InvokeMain(Action action);
}

/// <summary>
/// Default refusals, so a side only writes the members it actually has. Every
/// capability is optional except logging.
/// </summary>
public abstract class HostServicesBase : IHostServices
{
    public abstract AowlSide Side { get; }
    public abstract string HostName { get; }
    public virtual string HostVersion => "1.0.0";
    public virtual string SptVersion => string.Empty;
    public virtual string GameVersion => string.Empty;

    public abstract void Log(AowlLogLevel level, string source, string message);

    public virtual string DbGet(string path) =>
        throw new NotSupportedException($"{HostName} has no SPT database");

    public virtual void DbPatch(string path, string patchJson) =>
        throw new NotSupportedException($"{HostName} has no SPT database");

    public virtual void RegisterRoute(string url, AowlRouteKind kind, RouteHandler handler) =>
        throw new NotSupportedException($"{HostName} does not serve HTTP routes");

    public virtual void RegisterPatch(string target, AowlPatchKind kind, PatchHandler handler) =>
        throw new NotSupportedException($"{HostName} does not support patching");

    public virtual string Call(string target, string argsJson) =>
        throw new NotSupportedException($"{HostName} has no reflection bridge");

    public virtual ulong Resolve(string typeName) =>
        throw new NotSupportedException($"{HostName} has no service resolver");

    public virtual void ReleaseHandle(ulong handle) { }

    public virtual void Schedule(int delayMs, Action action) =>
        throw new NotSupportedException($"{HostName} has no scheduler");

    public virtual void InvokeMain(Action action) => action();
}
