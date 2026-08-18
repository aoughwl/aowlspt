// aowlspt-sim — run a native mod with no game and no server.
//
// This is the piece that makes native modding bearable. Without it, the edit
// loop is: build, start the SPT server (or the whole game), click into a raid,
// find out the mod is wrong, kill everything, repeat. With it, the loop is one
// command that runs in under a second and can be attached to by gdb or Visual
// Studio like any other process.
//
// It implements the same IHostServices the real hosts do, so a mod cannot tell
// the difference except by asking `side()`. The SPT database is a JSON file you
// supply, `call` targets are scripted from a JSON file, and both are optional.
//
//   aowlspt-sim <mod-dir-or-library> [options]
//
//     --ticks N          run N update ticks (default 3)
//     --tick-ms N        milliseconds between ticks (default 16)
//     --db FILE          JSON file to serve as the SPT database
//     --stubs FILE       JSON map of "Type::Member" -> canned result for `call`
//     --route URL[,BODY] invoke a registered route and print the response
//     --emit NAME[,JSON] publish an event after load
//     --side server|client|sim   which side to present as (default sim)
//     --spt-version V    what to report as the SPT version
//     --watch            rebuild-and-reload when the library changes
//     --quiet            only warnings and errors

using System.Diagnostics;
using Aowlspt.Abi;

namespace Aowlspt.Sim;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length == 0 || args[0] is "-h" or "--help")
        {
            PrintUsage();
            return args.Length == 0 ? 2 : 0;
        }

        Options opts;
        try { opts = Options.Parse(args); }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine($"aowlspt-sim: {ex.Message}");
            return 2;
        }

        var services = new SimHostServices(opts);
        using var host = new ModHost(services);

        var (dir, lib) = ResolveTarget(opts.Target);
        if (lib is null)
        {
            Console.Error.WriteLine($"aowlspt-sim: no mod library found at '{opts.Target}'");
            return 2;
        }

        var mod = host.TryLoad(dir, lib);
        if (mod is null)
        {
            Console.Error.WriteLine("aowlspt-sim: the mod did not load");
            return 1;
        }

        host.StartAll();
        services.DrainScheduled();

        foreach (var (name, payload) in opts.Emits)
        {
            services.Log(AowlLogLevel.Info, "sim", $"emit {name}");
            host.Emit(name, payload);
            services.DrainScheduled();
        }

        foreach (var (url, body) in opts.Routes)
        {
            if (!services.TryInvokeRoute(url, body, "sim-session", out var response))
            {
                Console.Error.WriteLine($"aowlspt-sim: no route registered for '{url}'");
                continue;
            }
            services.Log(AowlLogLevel.Success, "sim", $"{url} -> {response}");
        }

        var clock = Stopwatch.StartNew();
        var previous = 0L;
        for (var i = 0; i < opts.Ticks; i++)
        {
            Thread.Sleep(opts.TickMs);
            var now = clock.ElapsedMilliseconds;
            host.UpdateAll(now - previous);
            previous = now;
            services.DrainScheduled();
        }

        if (opts.Watch) return Watch(host, services, mod, opts);

        host.UnloadAll();
        return services.ErrorCount > 0 ? 1 : 0;
    }

    /// <summary>
    /// Rebuild-and-reload: watch the library on disk and swap it live. This is
    /// the same code path the real hosts use, so if hot reload works here it
    /// works in a raid.
    /// </summary>
    private static int Watch(ModHost host, SimHostServices services, LoadedMod mod, Options opts)
    {
        services.Log(AowlLogLevel.Info, "sim",
            $"watching {Path.GetFileName(mod.SourceLibraryPath)} — Ctrl+C to stop");

        var guid = mod.Descriptor.Guid;
        var path = mod.SourceLibraryPath;
        var lastWrite = File.GetLastWriteTimeUtc(path);
        var stop = false;
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop = true; };

        var clock = Stopwatch.StartNew();
        var previous = 0L;
        while (!stop)
        {
            Thread.Sleep(opts.TickMs);

            var now = clock.ElapsedMilliseconds;
            host.UpdateAll(now - previous);
            previous = now;
            services.DrainScheduled();

            if (!File.Exists(path)) continue;
            var stamp = File.GetLastWriteTimeUtc(path);
            if (stamp == lastWrite) continue;

            // A build writes in chunks; wait for the file to stop changing
            // rather than loading a half-written DLL.
            Thread.Sleep(250);
            if (File.GetLastWriteTimeUtc(path) != stamp) continue;

            lastWrite = stamp;
            services.Reset();
            host.Reload(guid);
            services.DrainScheduled();
        }

        host.UnloadAll();
        return 0;
    }

    private static (string dir, string? lib) ResolveTarget(string target)
    {
        if (File.Exists(target))
            return (Path.GetDirectoryName(Path.GetFullPath(target)) ?? ".", Path.GetFullPath(target));

        if (Directory.Exists(target))
        {
            var full = Path.GetFullPath(target);
            var stem = new DirectoryInfo(full).Name;

            // Accept both the built layout (`bin/hello.dll`) and a flat one.
            foreach (var candidate in new[]
                     {
                         Path.Combine(full, "bin", NativeLibraryLoader.LibraryFileName(stem)),
                         Path.Combine(full, NativeLibraryLoader.LibraryFileName(stem)),
                     })
                if (File.Exists(candidate)) return (full, candidate);

            var pattern = NativeLibraryLoader.IsWindows ? "*.dll" : "*.so";
            foreach (var probe in new[] { Path.Combine(full, "bin"), full })
            {
                if (!Directory.Exists(probe)) continue;
                var found = Directory.GetFiles(probe, pattern);
                if (found.Length == 1) return (full, found[0]);
            }
            return (full, null);
        }

        return (".", null);
    }

    private static void PrintUsage() => Console.Error.WriteLine("""
        aowlspt-sim — run a native SPT mod with no game and no server

          aowlspt-sim <mod-dir-or-library> [options]

        Options
          --ticks N               update ticks to run (default 3)
          --tick-ms N             milliseconds between ticks (default 16)
          --db FILE               JSON file served as the SPT database
          --stubs FILE            JSON map of "Type::Member" -> canned `call` result
          --route URL[,BODY]      invoke a registered route, print the response
          --emit NAME[,JSON]      publish an event after load
          --side server|client|sim  which side to present as (default sim)
          --spt-version V         version to report as SPT's
          --watch                 reload the mod when its library changes
          --quiet                 only warnings and errors

        Examples
          aowlspt-sim examples/hello
          aowlspt-sim examples/hello --side server --route /aowlspt/hello
          aowlspt-sim examples/hello --watch --ticks 0
        """);
}
