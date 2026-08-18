// Harmony bridging for the client. Same shape as the server's bridge, but it
// runs against BepInEx's Harmony on Mono and serializes with Newtonsoft (the
// only JSON library reliably present in the game process).
//
// The one design point worth restating: Harmony patches are static methods
// picked at patch time, while native handlers are function pointers picked at
// run time. One fixed pair of static hooks looks up the handlers registered for
// whichever method is currently executing, so a single patch site serves every
// mod that attaches to it.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Aowlspt.Abi;
using HarmonyLib;
using Newtonsoft.Json;

namespace Aowlspt.Host.Client;

internal sealed class ClientHarmonyBridge : IDisposable
{
    private const string HarmonyId = "aowl.aowlspt.client";

    private static readonly Dictionary<MethodBase, List<PatchHandler>> Prefixes =
        new Dictionary<MethodBase, List<PatchHandler>>();
    private static readonly Dictionary<MethodBase, List<PatchHandler>> Postfixes =
        new Dictionary<MethodBase, List<PatchHandler>>();
    private static readonly object Gate = new object();

    private static readonly JsonSerializerSettings ArgSettings = new JsonSerializerSettings
    {
        ReferenceLoopHandling = ReferenceLoopHandling.Ignore,
        NullValueHandling = NullValueHandling.Ignore,
        MaxDepth = 6,
    };

    private readonly Harmony _harmony = new Harmony(HarmonyId);
    private readonly Action<AowlLogLevel, string, string> _log;

    public ClientHarmonyBridge(Action<AowlLogLevel, string, string> log) => _log = log;

    public void Patch(string target, AowlPatchKind kind, PatchHandler handler)
    {
        var method = ResolveMethod(target);

        Dictionary<MethodBase, List<PatchHandler>> table;
        if (kind == AowlPatchKind.Prefix) table = Prefixes;
        else if (kind == AowlPatchKind.Postfix) table = Postfixes;
        else throw new NotSupportedException(
            "finalizer patches are not bridged — exceptions do not cross the native boundary");

        bool alreadyPatched;
        lock (Gate)
        {
            List<PatchHandler>? list;
            alreadyPatched = table.TryGetValue(method, out list);
            if (!alreadyPatched) { list = new List<PatchHandler>(); table[method] = list; }
            list!.Add(handler);
        }

        if (alreadyPatched) return;

        var hookName = kind == AowlPatchKind.Prefix ? nameof(PrefixHook) : nameof(PostfixHook);
        var hook = new HarmonyMethod(typeof(ClientHarmonyBridge)
            .GetMethod(hookName, BindingFlags.NonPublic | BindingFlags.Static));

        _harmony.Patch(method,
            prefix: kind == AowlPatchKind.Prefix ? hook : null,
            postfix: kind == AowlPatchKind.Postfix ? hook : null);

        _log(AowlLogLevel.Debug, "aowlspt", $"harmony {kind} on {target}");
    }

    private static bool PrefixHook(MethodBase __originalMethod, object[] __args, ref object __result)
    {
        List<PatchHandler> handlers;
        lock (Gate)
        {
            List<PatchHandler>? found;
            if (!Prefixes.TryGetValue(__originalMethod, out found)) return true;
            handlers = found.ToList();
        }

        foreach (var handler in handlers)
        {
            var outcome = handler(Describe(__originalMethod), ArgsToJson(__args));
            if (!outcome.SkipOriginal) continue;

            var mi = __originalMethod as MethodInfo;
            if (!string.IsNullOrEmpty(outcome.ResultJson) && mi != null && mi.ReturnType != typeof(void))
            {
                try
                {
                    __result = JsonConvert.DeserializeObject(outcome.ResultJson!, mi.ReturnType)!;
                }
                catch (JsonException)
                {
                    // A replacement we cannot decode is worse than none: run the
                    // original rather than hand the game a default value.
                    return true;
                }
            }
            return false;
        }
        return true;
    }

    private static void PostfixHook(MethodBase __originalMethod, object[] __args)
    {
        List<PatchHandler> handlers;
        lock (Gate)
        {
            List<PatchHandler>? found;
            if (!Postfixes.TryGetValue(__originalMethod, out found)) return;
            handlers = found.ToList();
        }
        foreach (var handler in handlers)
            handler(Describe(__originalMethod), ArgsToJson(__args));
    }

    private static string Describe(MethodBase m) =>
        (m.DeclaringType != null ? m.DeclaringType.FullName : "?") + "::" + m.Name;

    private static string ArgsToJson(object[] args)
    {
        if (args == null || args.Length == 0) return "[]";
        try { return JsonConvert.SerializeObject(args, ArgSettings); }
        catch (Exception)
        {
            // EFT types frequently refuse to serialize. A type-name list still
            // tells the mod what it was called with.
            return "[" + string.Join(",", args
                .Select(a => "\"" + (a == null ? "null" : a.GetType().Name) + "\"")
                .ToArray()) + "]";
        }
    }

    private static MethodBase ResolveMethod(string target)
    {
        var split = target.IndexOf("::", StringComparison.Ordinal);
        if (split <= 0)
            throw new MissingMemberException($"'{target}' is not of the form Type::Method");

        var typeName = target.Substring(0, split);
        var methodName = target.Substring(split + 2);

        Type? type = null;
        var assemblies = AppDomain.CurrentDomain.GetAssemblies();
        foreach (var asm in assemblies)
        {
            type = asm.GetType(typeName, false, true);
            if (type != null) break;
        }
        if (type == null)
            type = assemblies.SelectMany(SafeTypes)
                .FirstOrDefault(t => string.Equals(t.Name, typeName, StringComparison.OrdinalIgnoreCase));

        if (type == null) throw new MissingMemberException($"no type '{typeName}' to patch");

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
        catch (ReflectionTypeLoadException ex) { return ex.Types.Where(t => t != null)!; }
    }

    public void Dispose()
    {
        // Only this instance's patches: a host shutdown must not disarm the
        // other client mods running alongside it.
        _harmony.UnpatchSelf();
        lock (Gate)
        {
            Prefixes.Clear();
            Postfixes.Clear();
        }
    }
}
