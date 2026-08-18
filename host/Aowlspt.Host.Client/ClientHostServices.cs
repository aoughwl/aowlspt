// The BepInEx client's side of IHostServices.
//
// Two things differ from the server in ways that matter to a mod author:
//
//  * There is no database and there are no HTTP routes. Those refuse with
//    ErrUnsupported, which is why a well-written mod guards them with `side()`.
//  * There is a hard main-thread rule. Unity will throw, or silently corrupt
//    state, if a GameObject is touched from a worker thread — so `invoke_main`
//    is not a convenience here, it is the only correct way for a mod's own
//    thread to reach the game.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Aowlspt.Abi;
using Newtonsoft.Json;
using UnityEngine;

namespace Aowlspt.Host.Client;

internal sealed class ClientHostServices : HostServicesBase
{
    private readonly Action<AowlLogLevel, string, string> _log;
    private readonly ClientHarmonyBridge _harmony;
    private readonly Dictionary<ulong, object> _handles = new Dictionary<ulong, object>();
    private readonly List<KeyValuePair<float, Action>> _scheduled = new List<KeyValuePair<float, Action>>();
    private readonly object _gate = new object();
    private ulong _nextHandle = 1;

    private static readonly JsonSerializerSettings JsonSettings = new JsonSerializerSettings
    {
        // Game objects are cyclic almost everywhere (a Player references its
        // inventory which references the Player). Serializing one without this
        // is a stack overflow, not an error message.
        ReferenceLoopHandling = ReferenceLoopHandling.Ignore,
        NullValueHandling = NullValueHandling.Ignore,
        MaxDepth = 12,
    };

    public ClientHostServices(Action<AowlLogLevel, string, string> log, string gameVersion)
    {
        _log = log;
        GameVersion = gameVersion;
        _harmony = new ClientHarmonyBridge(log);
    }

    public override AowlSide Side => AowlSide.Client;
    public override string HostName => "aowlspt-client";
    public override string HostVersion => "1.0.0";
    public override string GameVersion { get; }

    public override void Log(AowlLogLevel level, string source, string message) =>
        _log(level, source, message);

    // DbGet/DbPatch/RegisterRoute intentionally left to the base class, which
    // refuses them with a message naming this host.

    public override void RegisterPatch(string target, AowlPatchKind kind, PatchHandler handler) =>
        _harmony.Patch(target, kind, handler);

    // --------------------------------------------------- reflection bridge

    public override string Call(string target, string argsJson)
    {
        var split = target.IndexOf("::", StringComparison.Ordinal);
        if (split <= 0)
            throw new MissingMemberException($"'{target}' is not of the form Type::Member");

        var typeSpec = target.Substring(0, split);
        var memberName = target.Substring(split + 2);

        object? instance = null;
        Type type;

        if (typeSpec.StartsWith("#", StringComparison.Ordinal))
        {
            ulong handle;
            if (!ulong.TryParse(typeSpec.Substring(1), out handle) ||
                !_handles.TryGetValue(handle, out instance))
                throw new MissingMemberException($"handle {typeSpec} is not live");
            type = instance.GetType();
        }
        else
        {
            type = FindType(typeSpec);
            if (type == null) throw new MissingMemberException($"no type '{typeSpec}'");
        }

        var args = ParseArgs(argsJson);
        var method = SelectMethod(type, memberName, args.Length);

        if (method == null)
        {
            var prop = type.GetProperty(memberName,
                BindingFlags.Public | BindingFlags.NonPublic |
                BindingFlags.Instance | BindingFlags.Static | BindingFlags.IgnoreCase);
            if (prop == null)
                throw new MissingMemberException(
                    $"'{typeSpec}' has no member '{memberName}' taking {args.Length} argument(s)");
            return Serialize(prop.GetValue(instance));
        }

        var parameters = method.GetParameters();
        var bound = new object?[parameters.Length];
        for (var i = 0; i < parameters.Length; i++)
            bound[i] = i < args.Length
                ? DeserializeArg(args[i], parameters[i].ParameterType)
                : (parameters[i].IsOptional ? parameters[i].DefaultValue : null);

        return Serialize(method.Invoke(method.IsStatic ? null : instance, bound));
    }

    /// <summary>
    /// Resolve a live Unity component by type name. Unlike the server, there is
    /// no container to ask — the scene is the registry, so this is a
    /// FindObjectOfType against the loaded types.
    /// </summary>
    public override ulong Resolve(string typeName)
    {
        var type = FindType(typeName);
        if (type == null) throw new MissingMemberException($"no type '{typeName}'");

        object? found = null;
        if (typeof(UnityEngine.Object).IsAssignableFrom(type))
            found = UnityEngine.Object.FindObjectOfType(type);

        if (found == null)
            throw new MissingMemberException(
                $"no live instance of '{typeName}' in the scene — resolve during a raid, not at startup");

        var handle = _nextHandle++;
        _handles[handle] = found;
        return handle;
    }

    public override void ReleaseHandle(ulong handle) => _handles.Remove(handle);

    private static JsonValue[] ParseArgs(string argsJson)
    {
        if (string.IsNullOrEmpty(argsJson) || argsJson.Trim().Length == 0)
            return new JsonValue[0];
        JsonValue parsed;
        if (!JsonValue.TryParse(argsJson, out parsed))
            throw new FormatException("call arguments are not valid JSON");
        return parsed.Kind == JsonKind.Array ? parsed.Items.ToArray() : new[] { parsed };
    }

    private static MethodInfo? SelectMethod(Type type, string name, int argCount)
    {
        return type
            .GetMethods(BindingFlags.Public | BindingFlags.NonPublic |
                        BindingFlags.Instance | BindingFlags.Static)
            .FirstOrDefault(m =>
                string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase) &&
                m.GetParameters().Length >= argCount &&
                m.GetParameters().Count(p => !p.IsOptional) <= argCount);
    }

    private static object? DeserializeArg(JsonValue value, Type target) =>
        JsonConvert.DeserializeObject(value.ToString(), target);

    private static string Serialize(object? value)
    {
        if (value == null) return "null";
        try { return JsonConvert.SerializeObject(value, JsonSettings); }
        catch (Exception ex)
        {
            // Plenty of EFT types cannot be serialized at all. Reporting the type
            // is more use to a mod author than an exception that kills the call.
            return JsonConvert.SerializeObject(new
            {
                unserializable = value.GetType().FullName,
                reason = ex.Message,
            });
        }
    }

    /// <summary>
    /// Find a type across the loaded assemblies, by full name or simple name.
    /// Simple names matter here more than on the server: EFT's obfuscated types
    /// get renamed every patch (GClass1234 → GClass1567), and SPT's own rename
    /// map moves them again.
    /// </summary>
    private static Type? FindType(string name)
    {
        var direct = Type.GetType(name, false, true);
        if (direct != null) return direct;

        var assemblies = AppDomain.CurrentDomain.GetAssemblies();

        foreach (var asm in assemblies)
        {
            var byFullName = asm.GetType(name, false, true);
            if (byFullName != null) return byFullName;
        }

        foreach (var asm in assemblies)
        {
            Type[] types;
            try { types = asm.GetTypes(); }
            catch (ReflectionTypeLoadException ex) { types = ex.Types.Where(t => t != null).ToArray()!; }

            foreach (var t in types)
                if (t != null && string.Equals(t.Name, name, StringComparison.OrdinalIgnoreCase))
                    return t;
        }
        return null;
    }

    // ---------------------------------------------------------- scheduling

    public override void Schedule(int delayMs, Action action)
    {
        lock (_gate)
            _scheduled.Add(new KeyValuePair<float, Action>(
                Time.realtimeSinceStartup + Math.Max(0, delayMs) / 1000f, action));
    }

    public override void InvokeMain(Action action)
    {
        lock (_gate) _scheduled.Add(new KeyValuePair<float, Action>(0f, action));
    }

    /// <summary>Run everything now due. Called from Plugin.Update, on Unity's main thread.</summary>
    public void DrainScheduled()
    {
        List<Action> due = new List<Action>();
        lock (_gate)
        {
            var now = Time.realtimeSinceStartup;
            for (var i = _scheduled.Count - 1; i >= 0; i--)
            {
                if (_scheduled[i].Key > now) continue;
                due.Add(_scheduled[i].Value);
                _scheduled.RemoveAt(i);
            }
        }
        foreach (var work in due)
        {
            try { work(); }
            catch (Exception ex) { Log(AowlLogLevel.Error, "aowlspt", "scheduled work threw: " + ex.Message); }
        }
    }

    public void DisposeHarmony() => _harmony.Dispose();
}
