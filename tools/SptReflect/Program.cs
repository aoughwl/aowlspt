// sptreflect — dumps the public API surface of the SPT 4.x server assemblies.
//
// Reads assemblies with MetadataLoadContext (metadata only, never executes SPT
// code and never writes into the SPT install).
//
// This targets SPT 4.x, which is a pre-1.0 (Mono) project, and aowlspt no longer
// builds anything against SPT: the live path is the nimony backend
// (`aowlspt-backend`) and the native IL2CPP client host. It is kept for one
// reason -- it is what produces `reference/spt-4.1-surface.*`, and the ~590
// `SPTarkov.Server.Core.Models.Eft` types in that dump are the closest thing
// there is to a written spec of the request and response shapes the Tarkov
// client speaks. The emulator in `mods/tarkov` has to match those shapes, and
// the wire protocol does not care whether the client is Mono or IL2CPP. Re-run
// it when SPT updates; see `reference/README.md`.
//
//   sptreflect <spt-runtime-dir> [--filter <substring>] [--json <out>] [--members]
//
using System.Reflection;
using System.Text;
using System.Text.Json;

namespace Aowlspt.Tools.SptReflect;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("usage: sptreflect <spt-runtime-dir> [--filter <substr>]... [--json <out>] [--members] [--assembly <name>]");
            return 2;
        }

        var runtimeDir = args[0];
        if (!Directory.Exists(runtimeDir))
        {
            Console.Error.WriteLine($"error: not a directory: {runtimeDir}");
            return 2;
        }

        var filters = new List<string>();
        string? jsonOut = null;
        var withMembers = false;
        var assemblies = new List<string>();

        for (var i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--filter" when i + 1 < args.Length: filters.Add(args[++i]); break;
                case "--json" when i + 1 < args.Length: jsonOut = args[++i]; break;
                case "--assembly" when i + 1 < args.Length: assemblies.Add(args[++i]); break;
                case "--members": withMembers = true; break;
                default:
                    Console.Error.WriteLine($"error: unknown argument: {args[i]}");
                    return 2;
            }
        }

        if (assemblies.Count == 0)
        {
            assemblies.AddRange(["SPTarkov.Server.Core", "SPTarkov.DI", "SPTarkov.Common", "SPTarkov.Server.Web"]);
        }

        var paths = new List<string>(Directory.GetFiles(runtimeDir, "*.dll"));
        paths.AddRange(RefPackDlls());

        using var mlc = new MetadataLoadContext(new PathAssemblyResolver(paths));

        var dumped = new List<TypeInfoDto>();
        foreach (var name in assemblies)
        {
            var path = Path.Combine(runtimeDir, name + ".dll");
            if (!File.Exists(path))
            {
                Console.Error.WriteLine($"warn: missing assembly {path}");
                continue;
            }

            Assembly asm;
            try { asm = mlc.LoadFromAssemblyPath(path); }
            catch (Exception ex) { Console.Error.WriteLine($"warn: load failed {name}: {ex.Message}"); continue; }

            foreach (var type in SafeTypes(asm))
            {
                if (!type.IsPublic && !type.IsNestedPublic) continue;
                var full = type.FullName ?? type.Name;
                if (filters.Count > 0 && !filters.Any(f => full.Contains(f, StringComparison.OrdinalIgnoreCase))) continue;
                dumped.Add(Describe(type, withMembers));
            }
        }

        dumped.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));

        if (jsonOut is not null)
        {
            var json = JsonSerializer.Serialize(dumped, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(jsonOut, json, new UTF8Encoding(false));
            Console.Error.WriteLine($"wrote {dumped.Count} type(s) -> {jsonOut}");
        }

        foreach (var t in dumped)
        {
            Console.WriteLine($"{t.Kind} {t.Name}{(t.Bases.Count > 0 ? " : " + string.Join(", ", t.Bases) : "")}");
            foreach (var m in t.Members) Console.WriteLine($"    {m}");
        }

        return 0;
    }

    private static IEnumerable<Type> SafeTypes(Assembly asm)
    {
        try { return asm.GetTypes(); }
        catch (ReflectionTypeLoadException ex) { return ex.Types.Where(t => t is not null)!; }
    }

    private static TypeInfoDto Describe(Type type, bool withMembers)
    {
        var kind = type.IsInterface ? "interface"
            : type.IsEnum ? "enum"
            : type.IsValueType ? "struct"
            : type.IsAbstract && type.IsSealed ? "static class"
            : "class";

        var bases = new List<string>();
        if (type.BaseType is { } bt && bt.FullName != "System.Object" && bt.FullName != "System.ValueType")
            bases.Add(Short(bt));
        foreach (var i in type.GetInterfaces()) bases.Add(Short(i));

        var members = new List<string>();
        if (withMembers)
        {
            const BindingFlags flags = BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly;

            // A signature can name a type outside the resolver set; that member is
            // skipped rather than losing the whole type.
            Try(() =>
            {
                foreach (var m in type.GetMethods(flags))
                {
                    if (m.IsSpecialName) continue;
                    Try(() =>
                    {
                        var ps = string.Join(", ", m.GetParameters().Select(p => $"{Short(p.ParameterType)} {p.Name}"));
                        members.Add($"{(m.IsStatic ? "static " : "")}{Short(m.ReturnType)} {m.Name}({ps})");
                    });
                }
            });
            // Constructors matter here: SPT's router base classes take their route
            // tables through the ctor, so the binding layer has to match them.
            Try(() =>
            {
                foreach (var c in type.GetConstructors(flags | BindingFlags.NonPublic))
                {
                    if (c.IsPrivate) continue;
                    Try(() =>
                    {
                        var ps = string.Join(", ", c.GetParameters().Select(p => $"{Short(p.ParameterType)} {p.Name}"));
                        members.Add($"ctor {(c.IsFamily ? "protected " : "")}.ctor({ps})");
                    });
                }
            });
            Try(() =>
            {
                foreach (var p in type.GetProperties(flags))
                    Try(() => members.Add($"prop {Short(p.PropertyType)} {p.Name}"));
            });
            Try(() =>
            {
                foreach (var f in type.GetFields(flags))
                    Try(() => members.Add($"field {Short(f.FieldType)} {f.Name}"));
            });
            members.Sort(StringComparer.Ordinal);
        }

        var attrs = new List<string>();
        try
        {
            foreach (var a in type.GetCustomAttributesData())
            {
                var an = a.AttributeType.Name;
                var argv = a.ConstructorArguments.Count > 0
                    ? "(" + string.Join(", ", a.ConstructorArguments.Select(x => x.Value?.ToString() ?? "null")) + ")"
                    : "";
                attrs.Add(an + argv);
            }
        }
        catch { /* attribute types outside the resolver set */ }

        return new TypeInfoDto(type.FullName ?? type.Name, kind, bases, members, attrs);
    }

    private static void Try(Action action)
    {
        try { action(); }
        catch (FileNotFoundException) { }
        catch (TypeLoadException) { }
        catch (BadImageFormatException) { }
    }

    private static string Short(Type t)
    {
        if (!t.IsGenericType) return t.Name;
        var name = t.Name;
        var tick = name.IndexOf('`');
        if (tick > 0) name = name[..tick];
        return $"{name}<{string.Join(", ", t.GetGenericArguments().Select(Short))}>";
    }

    // The resolver needs every assembly SPT's public signatures mention — that
    // includes ASP.NET Core types on the router/listener surface, which do not
    // live in the base runtime directory.
    private static IEnumerable<string> RefPackDlls()
    {
        var dirs = new List<string>();

        var baseDir = Path.GetDirectoryName(typeof(object).Assembly.Location);
        if (!string.IsNullOrEmpty(baseDir)) dirs.Add(baseDir);

        var dotnetRoot = Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(baseDir)));
        if (!string.IsNullOrEmpty(dotnetRoot))
        {
            foreach (var shared in new[] { "Microsoft.AspNetCore.App", "Microsoft.NETCore.App" })
            {
                var sharedDir = Path.Combine(dotnetRoot, "shared", shared);
                if (!Directory.Exists(sharedDir)) continue;
                // newest installed version wins
                var newest = Directory.GetDirectories(sharedDir).OrderBy(d => d, StringComparer.Ordinal).LastOrDefault();
                if (newest is not null) dirs.Add(newest);
            }
        }

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var dir in dirs)
        foreach (var dll in Directory.GetFiles(dir, "*.dll"))
            if (seen.Add(Path.GetFileName(dll)))
                yield return dll;
    }
}

internal sealed record TypeInfoDto(
    string Name,
    string Kind,
    List<string> Bases,
    List<string> Members,
    List<string> Attributes);
