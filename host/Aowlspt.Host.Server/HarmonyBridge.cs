// Turns "Namespace.Type::Method" plus a native callback into a Harmony patch.
//
// The awkward part of bridging Harmony to a C ABI is that Harmony patches are
// static methods chosen at patch time, while a native handler is a function
// pointer chosen at run time. The bridge is a fixed pair of static hooks that
// look up which native handler belongs to the method currently executing, keyed
// by MethodBase — so one pair of hooks serves every patch from every mod.

using System.Reflection;
using Aowlspt.Abi;
using HarmonyLib;

namespace Aowlspt.Host.Server;

internal sealed class HarmonyBridge : IDisposable
{
    private const string HarmonyId = "aowl.aowlspt.host";

    private static readonly Dictionary<MethodBase, List<PatchHandler>> Prefixes = new();
    private static readonly Dictionary<MethodBase, List<PatchHandler>> Postfixes = new();
    private static readonly object Gate = new();

    private readonly Harmony _harmony = new(HarmonyId);
    private readonly Action<AowlLogLevel, string, string> _log;

    public HarmonyBridge(Action<AowlLogLevel, string, string> log) => _log = log;

    public void Patch(string target, AowlPatchKind kind, PatchHandler handler)
    {
        var method = ResolveMethod(target);

        var table = kind switch
        {
            AowlPatchKind.Prefix => Prefixes,
            AowlPatchKind.Postfix => Postfixes,
            // A finalizer's contract is about exceptions, which do not cross the
            // C ABI in any useful form. Saying so beats pretending to support it.
            _ => throw new NotSupportedException(
                "finalizer patches are not bridged — exceptions do not cross the native boundary"),
        };

        bool alreadyPatched;
        lock (Gate)
        {
            alreadyPatched = table.TryGetValue(method, out var list);
            if (!alreadyPatched) { list = new List<PatchHandler>(); table[method] = list; }
            list!.Add(handler);
        }

        // Patch the method once, however many mods attach to it; the hook fans
        // out to each registered handler in turn.
        if (alreadyPatched) return;

        var hook = kind == AowlPatchKind.Prefix
            ? new HarmonyMethod(typeof(HarmonyBridge).GetMethod(nameof(PrefixHook),
                BindingFlags.NonPublic | BindingFlags.Static))
            : new HarmonyMethod(typeof(HarmonyBridge).GetMethod(nameof(PostfixHook),
                BindingFlags.NonPublic | BindingFlags.Static));

        _harmony.Patch(method,
            prefix: kind == AowlPatchKind.Prefix ? hook : null,
            postfix: kind == AowlPatchKind.Postfix ? hook : null);

        _log(AowlLogLevel.Debug, "aowlspt", $"harmony {kind} on {target}");
    }

    private static bool PrefixHook(MethodBase __originalMethod, object?[] __args, ref object? __result)
    {
        List<PatchHandler> handlers;
        lock (Gate)
        {
            if (!Prefixes.TryGetValue(__originalMethod, out var found)) return true;
            handlers = found.ToList();
        }

        foreach (var handler in handlers)
        {
            var outcome = handler(Describe(__originalMethod), ArgsToJson(__args));
            if (!outcome.SkipOriginal) continue;

            // The mod replaced the result: decode it into the declared return
            // type and skip the original.
            if (!string.IsNullOrEmpty(outcome.ResultJson) &&
                __originalMethod is MethodInfo mi && mi.ReturnType != typeof(void))
            {
                try
                {
                    __result = System.Text.Json.JsonSerializer.Deserialize(
                        outcome.ResultJson!, mi.ReturnType,
                        new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                }
                catch (System.Text.Json.JsonException)
                {
                    // A replacement we cannot decode is worse than no replacement:
                    // run the original rather than hand the game a default value.
                    return true;
                }
            }
            return false;
        }
        return true;
    }

    private static void PostfixHook(MethodBase __originalMethod, object?[] __args)
    {
        List<PatchHandler> handlers;
        lock (Gate)
        {
            if (!Postfixes.TryGetValue(__originalMethod, out var found)) return;
            handlers = found.ToList();
        }
        foreach (var handler in handlers)
            handler(Describe(__originalMethod), ArgsToJson(__args));
    }

    private static string Describe(MethodBase m) =>
        $"{m.DeclaringType?.FullName}::{m.Name}";

    private static string ArgsToJson(object?[] args)
    {
        if (args.Length == 0) return "[]";
        try
        {
            return System.Text.Json.JsonSerializer.Serialize(args);
        }
        catch (Exception)
        {
            // Game objects routinely fail to serialize (cycles, Unity handles).
            // A type-name list still tells the mod what it was called with.
            return "[" + string.Join(",",
                args.Select(a => "\"" + (a?.GetType().Name ?? "null") + "\"")) + "]";
        }
    }

    private static MethodBase ResolveMethod(string target)
    {
        var split = target.IndexOf("::", StringComparison.Ordinal);
        if (split <= 0)
            throw new MissingMemberException($"'{target}' is not of the form Namespace.Type::Method");

        var typeName = target[..split];
        var methodName = target[(split + 2)..];

        Type? type = null;
        foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
        {
            type = asm.GetType(typeName, throwOnError: false, ignoreCase: true);
            if (type is not null) break;
        }
        type ??= AppDomain.CurrentDomain.GetAssemblies()
            .SelectMany(SafeTypes)
            .FirstOrDefault(t => string.Equals(t.Name, typeName, StringComparison.OrdinalIgnoreCase));

        if (type is null) throw new MissingMemberException($"no type '{typeName}' to patch");

        var methods = type
            .GetMethods(BindingFlags.Public | BindingFlags.NonPublic |
                        BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly)
            .Where(m => string.Equals(m.Name, methodName, StringComparison.Ordinal))
            .ToList();

        if (methods.Count == 0)
            throw new MissingMemberException($"'{typeName}' has no method '{methodName}'");
        if (methods.Count > 1)
            throw new AmbiguousMatchException(
                $"'{target}' is overloaded {methods.Count} ways — the ABI cannot pick one");

        return methods[0];
    }

    private static IEnumerable<Type> SafeTypes(Assembly asm)
    {
        try { return asm.GetTypes(); }
        catch (ReflectionTypeLoadException ex) { return ex.Types.Where(t => t is not null)!; }
    }

    public void Dispose()
    {
        // UnpatchSelf, not UnpatchAll: removing only this instance's patches
        // leaves every other mod's patches in place, which matters because a
        // host shutdown must not disarm the rest of the server.
        _harmony.UnpatchSelf();
        lock (Gate)
        {
            Prefixes.Clear();
            Postfixes.Clear();
        }
    }
}
