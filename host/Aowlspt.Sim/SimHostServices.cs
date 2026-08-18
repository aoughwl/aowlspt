// The simulator's side of IHostServices.
//
// Every capability the real hosts have is present, backed by something a
// developer can inspect and script: the database is a JSON file, `call` targets
// come from a stub map, routes and patches are recorded so a test can invoke
// them, and the "main thread" is this thread with a work queue.
//
// The point is that a mod exercises the same code paths here as in a raid.
// Anything the simulator cannot do, it refuses the same way the real host would.

using System.Collections.Concurrent;
using System.Diagnostics;
using Aowlspt.Abi;

namespace Aowlspt.Sim;

internal sealed class SimHostServices : HostServicesBase
{
    private readonly Options _opts;
    private readonly Dictionary<string, (AowlRouteKind Kind, RouteHandler Handler)> _routes = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, List<(AowlPatchKind Kind, PatchHandler Handler)>> _patches = new(StringComparer.Ordinal);
    private readonly ConcurrentQueue<(long DueAt, Action Work)> _queue = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly Dictionary<ulong, string> _handles = new();
    private ulong _nextHandle = 1;

    private JsonValue _db = JsonValue.Object();
    private JsonValue _stubs = JsonValue.Object();

    public int ErrorCount { get; private set; }

    public SimHostServices(Options opts)
    {
        _opts = opts;

        if (opts.DbFile is not null)
        {
            if (!File.Exists(opts.DbFile))
                Log(AowlLogLevel.Warn, "sim", $"--db file not found: {opts.DbFile}");
            else if (JsonValue.TryParse(File.ReadAllText(opts.DbFile), out var db))
                _db = db;
            else
                Log(AowlLogLevel.Warn, "sim", $"--db file is not valid JSON: {opts.DbFile}");
        }

        if (opts.StubFile is not null)
        {
            if (!File.Exists(opts.StubFile))
                Log(AowlLogLevel.Warn, "sim", $"--stubs file not found: {opts.StubFile}");
            else if (JsonValue.TryParse(File.ReadAllText(opts.StubFile), out var stubs))
                _stubs = stubs;
            else
                Log(AowlLogLevel.Warn, "sim", $"--stubs file is not valid JSON: {opts.StubFile}");
        }
    }

    public override AowlSide Side => _opts.Side;
    public override string HostName => "aowlspt-sim";
    public override string HostVersion => "1.0.0";
    public override string SptVersion => _opts.SptVersion;
    public override string GameVersion => string.Empty;

    /// <summary>Forget registrations made by a previous incarnation of a reloaded mod.</summary>
    public void Reset()
    {
        _routes.Clear();
        _patches.Clear();
    }

    // ------------------------------------------------------------- logging

    public override void Log(AowlLogLevel level, string source, string message)
    {
        if (level >= AowlLogLevel.Error) ErrorCount++;
        if (_opts.Quiet && level < AowlLogLevel.Warn) return;

        var (colour, tag) = level switch
        {
            AowlLogLevel.Trace => (ConsoleColor.DarkGray, "trace"),
            AowlLogLevel.Debug => (ConsoleColor.DarkGray, "debug"),
            AowlLogLevel.Info => (ConsoleColor.Gray, "info "),
            AowlLogLevel.Success => (ConsoleColor.Green, "ok   "),
            AowlLogLevel.Warn => (ConsoleColor.Yellow, "warn "),
            _ => (ConsoleColor.Red, "error"),
        };

        var writer = level >= AowlLogLevel.Warn ? Console.Error : Console.Out;
        var previous = Console.ForegroundColor;
        try
        {
            Console.ForegroundColor = colour;
            writer.WriteLine($"[{_clock.ElapsedMilliseconds,6}ms] {tag} {source}: {message}");
        }
        finally { Console.ForegroundColor = previous; }
    }

    // ------------------------------------------------------------ database

    public override string DbGet(string path)
    {
        var node = _db.GetPath(path);
        if (node is null) throw new KeyNotFoundException($"no database entry at '{path}'");
        return node.ToString();
    }

    public override void DbPatch(string path, string patchJson)
    {
        if (!JsonValue.TryParse(patchJson, out var patch))
            throw new FormatException($"db_patch payload for '{path}' is not valid JSON");

        var target = _db.GetPath(path);
        if (target is null)
        {
            // Creating the path is friendlier than refusing: a mod adding a new
            // item should not need the sim's db file to already mention it.
            _db.SetPath(path, patch);
            Log(AowlLogLevel.Debug, "sim", $"db created {path}");
            return;
        }
        target.Merge(patch);
        Log(AowlLogLevel.Debug, "sim", $"db patched {path}");
    }

    /// <summary>The database as it now stands — for a test to assert against.</summary>
    public string DumpDb() => _db.ToString(true);

    // -------------------------------------------------------------- routes

    public override void RegisterRoute(string url, AowlRouteKind kind, RouteHandler handler)
    {
        _routes[url] = (kind, handler);
    }

    public bool TryInvokeRoute(string url, string body, string session, out string response)
    {
        if (_routes.TryGetValue(url, out var exact))
        {
            response = exact.Handler(url, body, session);
            return true;
        }

        // A dynamic route matches by prefix, the same way the server's
        // DynamicRouter does, so a URL with parameters reaches its handler.
        foreach (var kv in _routes)
        {
            if (kv.Value.Kind != AowlRouteKind.Dynamic) continue;
            if (!url.StartsWith(kv.Key, StringComparison.OrdinalIgnoreCase)) continue;
            response = kv.Value.Handler(url, body, session);
            return true;
        }

        response = string.Empty;
        return false;
    }

    public IReadOnlyCollection<string> RegisteredRoutes => _routes.Keys;

    // ------------------------------------------------------------- patches

    public override void RegisterPatch(string target, AowlPatchKind kind, PatchHandler handler)
    {
        if (!_patches.TryGetValue(target, out var list))
        {
            list = new List<(AowlPatchKind, PatchHandler)>();
            _patches[target] = list;
        }
        list.Add((kind, handler));
    }

    /// <summary>
    /// Drive a patched method as the real Harmony bridge would, so a prefix
    /// patch's skip/replace behaviour can be tested without a game.
    /// </summary>
    public PatchOutcome InvokePatch(string target, string argsJson)
    {
        if (!_patches.TryGetValue(target, out var list)) return PatchOutcome.Continue;
        foreach (var (kind, handler) in list)
        {
            if (kind != AowlPatchKind.Prefix) continue;
            var outcome = handler(target, argsJson);
            if (outcome.SkipOriginal) return outcome;
        }
        return PatchOutcome.Continue;
    }

    // --------------------------------------------------- reflection bridge

    public override string Call(string target, string argsJson)
    {
        if (_stubs.TryGet(target, out var canned)) return canned.ToString();

        // Handle-form targets resolve to the type they came from, so a stub can
        // be written against "Type::Member" and still answer "#3::Member".
        if (target.StartsWith("#", StringComparison.Ordinal))
        {
            var split = target.IndexOf("::", StringComparison.Ordinal);
            if (split > 0 &&
                ulong.TryParse(target.AsSpan(1, split - 1), out var h) &&
                _handles.TryGetValue(h, out var typeName))
            {
                var rewritten = typeName + target[split..];
                if (_stubs.TryGet(rewritten, out var byType)) return byType.ToString();
            }
        }

        throw new MissingMemberException(
            $"no stub for '{target}'. Add it to the --stubs file to script this call.");
    }

    public override ulong Resolve(string typeName)
    {
        var h = _nextHandle++;
        _handles[h] = typeName;
        Log(AowlLogLevel.Debug, "sim", $"resolve {typeName} -> #{h}");
        return h;
    }

    public override void ReleaseHandle(ulong handle) => _handles.Remove(handle);

    // ---------------------------------------------------------- scheduling

    public override void Schedule(int delayMs, Action action) =>
        _queue.Enqueue((_clock.ElapsedMilliseconds + Math.Max(0, delayMs), action));

    public override void InvokeMain(Action action) =>
        _queue.Enqueue((0, action));

    /// <summary>
    /// Run everything now due. The simulator has one thread, so "the main
    /// thread" is whichever thread calls this — which is the honest model for a
    /// host that pumps a queue once per frame.
    /// </summary>
    public void DrainScheduled()
    {
        var now = _clock.ElapsedMilliseconds;
        var deferred = new List<(long, Action)>();

        while (_queue.TryDequeue(out var item))
        {
            if (item.DueAt > now) { deferred.Add(item); continue; }
            try { item.Work(); }
            catch (Exception ex) { Log(AowlLogLevel.Error, "sim", $"scheduled work threw: {ex.Message}"); }
        }

        foreach (var d in deferred) _queue.Enqueue(d);
    }
}
