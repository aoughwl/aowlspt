// The SPT server's side of IHostServices.
//
// Everything here is either a thin adapter onto an SPT service or a reflection
// walk. Deliberately little is hard-coded against SPT's shape: SPT 4.x renames
// types between point releases, and a host that names fifty of them breaks every
// time. What it does name is the eleven database tables, which are DI singletons
// with stable names, and it reaches everything else generically.

using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aowlspt.Abi;
using SPTarkov.Server.Core.Models.Spt.Tables;
using SPTarkov.Server.Core.Utils;

namespace Aowlspt.Host.Server;

internal sealed class ServerHostServices : HostServicesBase
{
    private readonly IServiceProvider _provider;
    private readonly Action<AowlLogLevel, string, string> _log;
    private readonly JsonUtil _jsonUtil;
    private readonly HarmonyBridge _harmony;
    private readonly Dictionary<ulong, object> _handles = new();
    private readonly List<(string Url, AowlRouteKind Kind, RouteHandler Handler)> _routes = new();
    private readonly List<(int DueAtMs, Action Work)> _scheduled = new();
    private readonly object _gate = new();
    private ulong _nextHandle = 1;

    /// <summary>
    /// The database roots, by the name a mod uses in a `db_get` path. These are
    /// SPT DI singletons; `db_get "templates.items.<id>"` resolves TemplateTable
    /// and then walks the rest of the path by reflection.
    /// </summary>
    private static readonly (string Name, Type Type)[] DatabaseRoots =
    {
        ("templates", typeof(TemplateTable)),
        ("traders", typeof(TradersTable)),
        ("globals", typeof(GlobalTable)),
        ("hideout", typeof(HideoutTable)),
        ("locales", typeof(LocaleTable)),
        ("locations", typeof(LocationTable)),
        ("bots", typeof(BotTable)),
        ("server", typeof(ServerTable)),
        ("settings", typeof(SettingsTable)),
        ("match", typeof(MatchTable)),
        ("exp", typeof(ExpTable)),
    };

    public ServerHostServices(
        IServiceProvider provider,
        JsonUtil jsonUtil,
        Action<AowlLogLevel, string, string> log,
        string sptVersion)
    {
        _provider = provider;
        _jsonUtil = jsonUtil;
        _log = log;
        SptVersion = sptVersion;
        _harmony = new HarmonyBridge(log);
    }

    public override AowlSide Side => AowlSide.Server;
    public override string HostName => "aowlspt-server";
    public override string HostVersion => "1.0.0";
    public override string SptVersion { get; }

    public override void Log(AowlLogLevel level, string source, string message) =>
        _log(level, source, message);

    // ------------------------------------------------------------ database

    public override string DbGet(string path)
    {
        var node = ResolvePath(path, out var resolved);
        if (!resolved) throw new KeyNotFoundException($"no database entry at '{path}'");
        return node is null ? "null" : _jsonUtil.Serialize(node, node.GetType(), false);
    }

    public override void DbPatch(string path, string patchJson)
    {
        if (!JsonValue.TryParse(patchJson, out var patch))
            throw new FormatException($"db_patch payload for '{path}' is not valid JSON");

        var target = ResolvePath(path, out var resolved);
        if (!resolved || target is null)
            throw new KeyNotFoundException($"no database entry at '{path}'");

        ApplyMerge(target, patch, path);
    }

    /// <summary>
    /// Walk a dotted path from a database root through properties, dictionary
    /// keys and list indices. `resolved` distinguishes "found, and it is null"
    /// from "not found", which the ABI reports differently.
    /// </summary>
    private object? ResolvePath(string path, out bool resolved)
    {
        resolved = false;
        var segments = (path ?? "").Split(new[] { '.' }, StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length == 0) throw new KeyNotFoundException("db path is empty");

        var root = DatabaseRoots.FirstOrDefault(r =>
            string.Equals(r.Name, segments[0], StringComparison.OrdinalIgnoreCase));
        if (root.Type is null)
            throw new KeyNotFoundException(
                $"'{segments[0]}' is not a database root. Known roots: {string.Join(", ", DatabaseRoots.Select(r => r.Name))}");

        object? node = _provider.GetService(root.Type);
        if (node is null) throw new KeyNotFoundException($"SPT did not provide {root.Type.Name}");

        for (var i = 1; i < segments.Length; i++)
        {
            if (node is null) return null;
            node = Step(node, segments[i]);
            if (node is Missing) return null;
        }

        resolved = true;
        return node;
    }

    /// <summary>Sentinel for "this segment did not match", distinct from a real null.</summary>
    private sealed class Missing { public static readonly Missing Instance = new(); }

    private static object? Step(object node, string segment)
    {
        var type = node.GetType();

        if (node is System.Collections.IDictionary dict)
        {
            foreach (System.Collections.DictionaryEntry entry in dict)
                if (string.Equals(entry.Key?.ToString(), segment, StringComparison.OrdinalIgnoreCase))
                    return entry.Value;
            return Missing.Instance;
        }

        if (node is System.Collections.IList list)
        {
            if (int.TryParse(segment, out var index) && index >= 0 && index < list.Count)
                return list[index];
            return Missing.Instance;
        }

        var prop = FindProperty(type, segment);
        if (prop is not null) return prop.GetValue(node);

        var field = type.GetField(segment,
            BindingFlags.Public | BindingFlags.Instance | BindingFlags.IgnoreCase);
        if (field is not null) return field.GetValue(node);

        return Missing.Instance;
    }

    private static readonly Dictionary<Type, Dictionary<string, PropertyInfo>> JsonNameCache = new();

    /// <summary>
    /// Find a property by the name a mod author would actually write.
    ///
    /// A db path is read off SPT's JSON — `templates.items.&lt;id&gt;._props.Weight` —
    /// but the C# member behind `_props` is called `Properties`, with the JSON
    /// name only in a [JsonPropertyName] attribute. Matching the C# name alone
    /// makes every documented path silently fail to resolve, so the JSON name is
    /// tried first and the C# name second.
    /// </summary>
    private static PropertyInfo? FindProperty(Type type, string name)
    {
        Dictionary<string, PropertyInfo> map;
        lock (JsonNameCache)
        {
            if (!JsonNameCache.TryGetValue(type, out map!))
            {
                map = new Dictionary<string, PropertyInfo>(StringComparer.OrdinalIgnoreCase);
                foreach (var p in type.GetProperties(BindingFlags.Public | BindingFlags.Instance))
                {
                    var json = p.GetCustomAttribute<JsonPropertyNameAttribute>()?.Name;
                    if (json is not null) map[json] = p;
                    // The C# name is a fallback, so an explicit JSON name wins.
                    if (!map.ContainsKey(p.Name)) map[p.Name] = p;
                }
                JsonNameCache[type] = map;
            }
        }
        return map.TryGetValue(name, out var found) ? found : null;
    }

    /// <summary>
    /// Merge a JSON patch onto a live object graph, field by field. Merging
    /// rather than replacing is the whole point: two mods editing sibling
    /// properties of the same item must not undo each other.
    /// </summary>
    private void ApplyMerge(object target, JsonValue patch, string path)
    {
        if (patch.Kind != JsonKind.Object)
            throw new FormatException($"db_patch at '{path}' needs a JSON object");

        var type = target.GetType();
        foreach (var kv in patch.Fields)
        {
            if (target is System.Collections.IDictionary dict)
            {
                var existing = Step(target, kv.Key);
                if (existing is not Missing && existing is not null && kv.Value.Kind == JsonKind.Object)
                {
                    ApplyMerge(existing, kv.Value, $"{path}.{kv.Key}");
                    continue;
                }
                // A dictionary's value type decides how the JSON is materialised.
                var valueType = DictionaryValueType(dict.GetType());
                dict[MatchingKey(dict, kv.Key)] = Deserialize(kv.Value, valueType);
                continue;
            }

            var prop = FindProperty(type, kv.Key);
            if (prop is null || !prop.CanRead)
            {
                Log(AowlLogLevel.Warn, "aowlspt",
                    $"db_patch: '{path}' has no member '{kv.Key}' — skipped");
                continue;
            }

            if (kv.Value.Kind == JsonKind.Object)
            {
                var existing = prop.GetValue(target);
                if (existing is not null)
                {
                    ApplyMerge(existing, kv.Value, $"{path}.{kv.Key}");
                    continue;
                }
            }

            if (!prop.CanWrite)
            {
                Log(AowlLogLevel.Warn, "aowlspt",
                    $"db_patch: '{path}.{kv.Key}' is read-only — skipped");
                continue;
            }

            prop.SetValue(target, Deserialize(kv.Value, prop.PropertyType));
        }
    }

    private static object MatchingKey(System.Collections.IDictionary dict, string key)
    {
        foreach (var k in dict.Keys)
            if (string.Equals(k?.ToString(), key, StringComparison.OrdinalIgnoreCase))
                return k!;
        return key;
    }

    private static Type DictionaryValueType(Type dictType)
    {
        var iface = dictType.GetInterfaces()
            .FirstOrDefault(i => i.IsGenericType &&
                                 i.GetGenericTypeDefinition() == typeof(IDictionary<,>));
        return iface?.GetGenericArguments()[1] ?? typeof(object);
    }

    private object? Deserialize(JsonValue value, Type target) =>
        JsonSerializer.Deserialize(value.ToString(), target,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

    // -------------------------------------------------------------- routes

    public override void RegisterRoute(string url, AowlRouteKind kind, RouteHandler handler)
    {
        lock (_gate) _routes.Add((url, kind, handler));
    }

    /// <summary>
    /// Dispatch an incoming request to a mod route.
    ///
    /// Routes are looked up per request rather than registered with SPT's DI,
    /// because DI construction happens before mods have loaded — a mod that
    /// registers a route in on_load would have missed the window. One dynamic
    /// router owns the "/aowlspt/" prefix and resolves through this table.
    /// </summary>
    public bool TryDispatch(string url, string body, string session, out string response)
    {
        (string Url, AowlRouteKind Kind, RouteHandler Handler)[] snapshot;
        lock (_gate) snapshot = _routes.ToArray();

        foreach (var r in snapshot)
            if (r.Kind == AowlRouteKind.Static &&
                string.Equals(r.Url, url, StringComparison.OrdinalIgnoreCase))
            {
                response = r.Handler(url, body, session);
                return true;
            }

        foreach (var r in snapshot)
            if (r.Kind == AowlRouteKind.Dynamic &&
                url.StartsWith(r.Url, StringComparison.OrdinalIgnoreCase))
            {
                response = r.Handler(url, body, session);
                return true;
            }

        response = string.Empty;
        return false;
    }

    public IReadOnlyList<string> RouteUrls
    {
        get { lock (_gate) return _routes.Select(r => r.Url).ToList(); }
    }

    // ------------------------------------------------------------- patching

    public override void RegisterPatch(string target, AowlPatchKind kind, PatchHandler handler) =>
        _harmony.Patch(target, kind, handler);

    // --------------------------------------------------- reflection bridge

    public override string Call(string target, string argsJson)
    {
        var split = target.IndexOf("::", StringComparison.Ordinal);
        if (split <= 0)
            throw new MissingMemberException($"'{target}' is not of the form Type::Member");

        var typeSpec = target[..split];
        var memberName = target[(split + 2)..];

        object? instance = null;
        Type type;

        if (typeSpec.StartsWith("#", StringComparison.Ordinal))
        {
            if (!ulong.TryParse(typeSpec.AsSpan(1), out var handle) ||
                !_handles.TryGetValue(handle, out var held))
                throw new MissingMemberException($"handle {typeSpec} is not live");
            instance = held;
            type = held.GetType();
        }
        else
        {
            type = FindType(typeSpec) ?? throw new MissingMemberException($"no type '{typeSpec}'");
            instance = _provider.GetService(type);   // null for a static call
        }

        var args = ParseArgs(argsJson);
        var method = SelectMethod(type, memberName, args.Length);
        if (method is null)
        {
            var prop = type.GetProperty(memberName,
                BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static | BindingFlags.IgnoreCase);
            if (prop is null)
                throw new MissingMemberException($"'{typeSpec}' has no member '{memberName}' taking {args.Length} argument(s)");
            var value = prop.GetValue(instance);
            return value is null ? "null" : _jsonUtil.Serialize(value, value.GetType(), false);
        }

        var parameters = method.GetParameters();
        var bound = new object?[parameters.Length];
        for (var i = 0; i < parameters.Length; i++)
            bound[i] = i < args.Length
                ? Deserialize(args[i], parameters[i].ParameterType)
                : (parameters[i].HasDefaultValue ? parameters[i].DefaultValue : null);

        var result = method.Invoke(method.IsStatic ? null : instance, bound);
        return result is null ? "null" : _jsonUtil.Serialize(result, result.GetType(), false);
    }

    private static JsonValue[] ParseArgs(string argsJson)
    {
        if (string.IsNullOrWhiteSpace(argsJson)) return Array.Empty<JsonValue>();
        if (!JsonValue.TryParse(argsJson, out var parsed))
            throw new FormatException("call arguments are not valid JSON");
        return parsed.Kind == JsonKind.Array ? parsed.Items.ToArray() : new[] { parsed };
    }

    private static MethodInfo? SelectMethod(Type type, string name, int argCount) =>
        type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static)
            .FirstOrDefault(m =>
                string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase) &&
                m.GetParameters().Count(p => !p.HasDefaultValue) <= argCount &&
                m.GetParameters().Length >= argCount);

    public override ulong Resolve(string typeName)
    {
        var type = FindType(typeName) ?? throw new MissingMemberException($"no type '{typeName}'");
        var service = _provider.GetService(type)
                      ?? throw new MissingMemberException($"SPT has no registered instance of '{typeName}'");
        var handle = _nextHandle++;
        _handles[handle] = service;
        return handle;
    }

    public override void ReleaseHandle(ulong handle) => _handles.Remove(handle);

    /// <summary>
    /// Find a type by full or simple name across the loaded SPT assemblies.
    /// Accepting a simple name matters in practice: SPT moves types between
    /// namespaces across point releases, and a mod that said "TemplateTable"
    /// should keep working when it moves.
    /// </summary>
    private static Type? FindType(string name)
    {
        var direct = Type.GetType(name, throwOnError: false, ignoreCase: true);
        if (direct is not null) return direct;

        foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
        {
            var byFullName = asm.GetType(name, throwOnError: false, ignoreCase: true);
            if (byFullName is not null) return byFullName;
        }

        foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
        {
            Type?[] types;
            try { types = asm.GetTypes(); }
            catch (ReflectionTypeLoadException ex) { types = ex.Types; }

            foreach (var t in types)
                if (t is not null && string.Equals(t.Name, name, StringComparison.OrdinalIgnoreCase))
                    return t;
        }
        return null;
    }

    // ---------------------------------------------------------- scheduling

    // The SPT server has no frame loop, so "the main thread" is the thread that
    // pumps IOnUpdate. Work queued here runs from ModEntry's update tick.
    public override void Schedule(int delayMs, Action action)
    {
        lock (_gate) _scheduled.Add((Environment.TickCount + Math.Max(0, delayMs), action));
    }

    public override void InvokeMain(Action action)
    {
        lock (_gate) _scheduled.Add((0, action));
    }

    public void DrainScheduled()
    {
        List<Action> due = new();
        lock (_gate)
        {
            var now = Environment.TickCount;
            for (var i = _scheduled.Count - 1; i >= 0; i--)
            {
                if (_scheduled[i].DueAtMs > now) continue;
                due.Add(_scheduled[i].Work);
                _scheduled.RemoveAt(i);
            }
        }
        foreach (var work in due)
        {
            try { work(); }
            catch (Exception ex) { Log(AowlLogLevel.Error, "aowlspt", $"scheduled work threw: {ex.Message}"); }
        }
    }

    public void DisposeHarmony() => _harmony.Dispose();
}
